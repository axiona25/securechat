import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pinenacl/ed25519.dart';
import 'api_service.dart';

/// SecureChat Protocol (SCP) Crypto Service — crypto_version=2
///
/// Handles:
/// - Key generation (Ed25519 identity + X25519 DH + signed prekey + OTPs)
/// - Secure storage of private keys
/// - Key bundle upload to server
/// - X3DH key agreement
/// - Interface for Double Ratchet (Phase 2)
class CryptoService {
  static const String _storagePrefix = 'scp_';
  static const int cryptoVersion = 2;

  // Secure storage keys
  static const String _identityPrivateKey = '${_storagePrefix}identity_private';
  static const String _identityPublicKey = '${_storagePrefix}identity_public';
  static const String _identityDhPrivateKey = '${_storagePrefix}identity_dh_private';
  static const String _identityDhPublicKey = '${_storagePrefix}identity_dh_public';
  static const String _signedPreKeyPrivate = '${_storagePrefix}signed_prekey_private';
  static const String _signedPreKeyPublic = '${_storagePrefix}signed_prekey_public';
  static const String _signedPreKeySignature = '${_storagePrefix}signed_prekey_signature';
  static const String _signedPreKeyTimestamp = '${_storagePrefix}signed_prekey_timestamp';
  static const String _otpkPrefix = '${_storagePrefix}otpk_';
  static const String _otpkCount = '${_storagePrefix}otpk_count';
  static const String _keysGenerated = '${_storagePrefix}keys_generated';
  static const String _keysUploaded = '${_storagePrefix}keys_uploaded';

  final FlutterSecureStorage _secureStorage;
  final ApiService _apiService;
  bool _initialized = false;

  CryptoService({
    required ApiService apiService,
    FlutterSecureStorage? secureStorage,
  })  : _apiService = apiService,
        _secureStorage = secureStorage ??
            FlutterSecureStorage(
              aOptions: const AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  // ============================================================
  // KEY GENERATION
  // ============================================================

  /// Generate complete key bundle and store private keys securely.
  /// Call this once at registration or first login.
  Future<Map<String, dynamic>> generateAndStoreKeyBundle() async {
    // 1. Generate Ed25519 identity keypair (for signing)
    final signingKey = SigningKey.generate();
    final identityPrivate = Uint8List.fromList(signingKey.seed.asTypedList);
    final identityPublic = Uint8List.fromList(signingKey.verifyKey.asTypedList);

    // 2. Generate X25519 identity DH keypair (for key exchange)
    final identityDhKey = PrivateKey.generate();
    final identityDhPublic = identityDhKey.publicKey;

    // 3. Generate X25519 signed prekey
    final signedPreKeyPrivate = PrivateKey.generate();
    final signedPreKeyPublic = signedPreKeyPrivate.publicKey;

    // 4. Sign the prekey with Ed25519 identity key
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final timestampBytes = _int64ToBytes(timestamp);
    final messageToSign = Uint8List.fromList([
      ...signedPreKeyPublic.asTypedList,
      ...timestampBytes,
    ]);

    final signedMessage = signingKey.sign(messageToSign);
    final signature = Uint8List.fromList(signedMessage.signature.asTypedList);

    // 5. Generate 100 one-time prekeys
    final List<Map<String, Uint8List>> oneTimePreKeys = [];
    for (int i = 0; i < 100; i++) {
      final otpkPrivate = PrivateKey.generate();
      final otpkPublic = otpkPrivate.publicKey;
      oneTimePreKeys.add({
        'private': Uint8List.fromList(otpkPrivate.asTypedList),
        'public': Uint8List.fromList(otpkPublic.asTypedList),
      });
    }

    // 6. Store ALL private keys in secure storage
    await _secureStorage.write(
      key: _identityPrivateKey,
      value: base64Encode(identityPrivate),
    );
    await _secureStorage.write(
      key: _identityPublicKey,
      value: base64Encode(identityPublic),
    );
    await _secureStorage.write(
      key: _identityDhPrivateKey,
      value: base64Encode(Uint8List.fromList(identityDhKey.asTypedList)),
    );
    await _secureStorage.write(
      key: _identityDhPublicKey,
      value: base64Encode(Uint8List.fromList(identityDhPublic.asTypedList)),
    );
    await _secureStorage.write(
      key: _signedPreKeyPrivate,
      value: base64Encode(Uint8List.fromList(signedPreKeyPrivate.asTypedList)),
    );
    await _secureStorage.write(
      key: _signedPreKeyPublic,
      value: base64Encode(Uint8List.fromList(signedPreKeyPublic.asTypedList)),
    );
    await _secureStorage.write(
      key: _signedPreKeySignature,
      value: base64Encode(signature),
    );
    await _secureStorage.write(
      key: _signedPreKeyTimestamp,
      value: timestamp.toString(),
    );

    for (int i = 0; i < oneTimePreKeys.length; i++) {
      await _secureStorage.write(
        key: '$_otpkPrefix${i}_private',
        value: base64Encode(oneTimePreKeys[i]['private']!),
      );
      await _secureStorage.write(
        key: '$_otpkPrefix${i}_public',
        value: base64Encode(oneTimePreKeys[i]['public']!),
      );
    }
    await _secureStorage.write(
      key: _otpkCount,
      value: oneTimePreKeys.length.toString(),
    );

    await _secureStorage.write(key: _keysGenerated, value: 'true');

    // 7. Return public bundle for upload
    return {
      'crypto_version': cryptoVersion,
      'identity_key_public': base64Encode(identityPublic),
      'identity_dh_key_public': base64Encode(Uint8List.fromList(identityDhPublic.asTypedList)),
      'signed_prekey_public': base64Encode(Uint8List.fromList(signedPreKeyPublic.asTypedList)),
      'signed_prekey_signature': base64Encode(signature),
      'signed_prekey_timestamp': timestamp,
      'one_time_prekeys': oneTimePreKeys.map((otpk) => base64Encode(otpk['public']!)).toList(),
    };
  }

  // ============================================================
  // KEY UPLOAD
  // ============================================================

  /// Upload public key bundle to server.
  /// Call after generateAndStoreKeyBundle().
  Future<bool> uploadKeyBundle(Map<String, dynamic> publicBundle) async {
    try {
      print('[CryptoService] Upload payload keys: ${publicBundle.keys.toList()}');
      print('[CryptoService] identity_key_public is null: ${publicBundle['identity_key_public'] == null}');
      final _ik = publicBundle['identity_key_public']?.toString();
      print('[CryptoService] identity_key_public value: ${_ik != null && _ik.length > 20 ? '${_ik.substring(0, 20)}...' : _ik}');
      await _apiService.post(
        '/encryption/keys/upload/',
        body: publicBundle,
      );
      await _secureStorage.write(key: _keysUploaded, value: 'true');
      debugPrint('[CryptoService] Key bundle uploaded successfully');
      return true;
    } on ApiException catch (e) {
      debugPrint('[CryptoService] Key upload failed: ${e.statusCode} - ${e.message} ${e.errors}');
      return false;
    } catch (e) {
      debugPrint('[CryptoService] Key upload error: $e');
      return false;
    }
  }

  /// Generate keys and upload in one step.
  Future<bool> initializeKeys() async {
    try {
      final alreadyGenerated = await _secureStorage.read(key: _keysGenerated);
      final alreadyUploaded = await _secureStorage.read(key: _keysUploaded);

      // Verify keys actually exist (not just flags)
      final hasPrivateKey = await _secureStorage.read(key: _identityPrivateKey) != null;

      if (alreadyGenerated == 'true' && alreadyUploaded == 'true' && hasPrivateKey) {
        debugPrint('[CryptoService] Keys already initialized');
        _initialized = true;
        return true;
      }

      Map<String, dynamic> publicBundle;
      if (alreadyGenerated != 'true' || !hasPrivateKey) {
        debugPrint('[CryptoService] Generating new key bundle...');
        publicBundle = await generateAndStoreKeyBundle();
      } else {
        publicBundle = await _rebuildPublicBundle();
      }

      debugPrint('[CryptoService] Uploading key bundle...');
      return await uploadKeyBundle(publicBundle);
    } catch (e) {
      debugPrint('[CryptoService] initializeKeys error: $e');
      return false;
    }
  }

  // ============================================================
  // KEY RETRIEVAL (from secure storage)
  // ============================================================

  /// Check if keys have been generated and uploaded.
  Future<bool> get isInitialized async {
    final generated = await _secureStorage.read(key: _keysGenerated);
    final uploaded = await _secureStorage.read(key: _keysUploaded);
    return generated == 'true' && uploaded == 'true';
  }

  /// Get identity public key (Ed25519, 32 bytes).
  Future<Uint8List?> getIdentityPublicKey() async {
    final b64 = await _secureStorage.read(key: _identityPublicKey);
    return b64 != null ? base64Decode(b64) : null;
  }

  /// Get identity DH private key (X25519, 32 bytes).
  Future<Uint8List?> getIdentityDhPrivateKey() async {
    final b64 = await _secureStorage.read(key: _identityDhPrivateKey);
    return b64 != null ? base64Decode(b64) : null;
  }

  /// Get identity DH public key (X25519, 32 bytes).
  Future<Uint8List?> getIdentityDhPublicKey() async {
    final b64 = await _secureStorage.read(key: _identityDhPublicKey);
    return b64 != null ? base64Decode(b64) : null;
  }

  /// Get signed prekey private (X25519, 32 bytes).
  Future<Uint8List?> getSignedPreKeyPrivate() async {
    final b64 = await _secureStorage.read(key: _signedPreKeyPrivate);
    return b64 != null ? base64Decode(b64) : null;
  }

  /// Get signed prekey public (X25519, 32 bytes).
  Future<Uint8List?> getSignedPreKeyPublic() async {
    final b64 = await _secureStorage.read(key: _signedPreKeyPublic);
    return b64 != null ? base64Decode(b64) : null;
  }

  /// Get a specific one-time prekey private key by index.
  Future<Uint8List?> getOneTimePreKeyPrivate(int index) async {
    final b64 = await _secureStorage.read(key: '$_otpkPrefix${index}_private');
    return b64 != null ? base64Decode(b64) : null;
  }

  /// Get the first available one-time prekey private key (for receiver X3DH).
  /// Returns null if none stored. Used when decrypting first message — server may have assigned any OTP.
  Future<Uint8List?> getFirstAvailableOneTimePreKeyPrivate() async {
    final countStr = await _secureStorage.read(key: _otpkCount);
    final count = int.tryParse(countStr ?? '0') ?? 0;
    for (int i = 0; i < count && i < 100; i++) {
      final b64 = await _secureStorage.read(key: '$_otpkPrefix${i}_private');
      if (b64 != null) return base64Decode(b64);
    }
    return null;
  }

  /// Delete a one-time prekey after it's been used (forward secrecy).
  Future<void> deleteOneTimePreKey(int index) async {
    await _secureStorage.delete(key: '$_otpkPrefix${index}_private');
    await _secureStorage.delete(key: '$_otpkPrefix${index}_public');
  }

  // ============================================================
  // KEY REPLENISHMENT
  // ============================================================

  /// Check prekey count on server and replenish if needed.
  Future<void> checkAndReplenishPreKeys() async {
    try {
      final data = await _apiService.get('/encryption/keys/count/');
      final count = data['available_prekeys'] ?? data['count'] ?? 0;
      if (count is int && count < 20) {
        debugPrint('[CryptoService] Low prekey count ($count), replenishing...');
        await _replenishPreKeys(50);
      }
    } catch (e) {
      debugPrint('[CryptoService] checkAndReplenishPreKeys error: $e');
    }
  }

  Future<void> _replenishPreKeys(int count) async {
    final currentCountStr = await _secureStorage.read(key: _otpkCount);
    final currentCount = int.tryParse(currentCountStr ?? '0') ?? 0;

    final List<Map<String, dynamic>> newPrekeys = [];

    for (int i = 0; i < count; i++) {
      final idx = currentCount + i;
      final otpkPrivate = PrivateKey.generate();
      final otpkPublic = otpkPrivate.publicKey;

      await _secureStorage.write(
        key: '$_otpkPrefix${idx}_private',
        value: base64Encode(Uint8List.fromList(otpkPrivate.asTypedList)),
      );
      await _secureStorage.write(
        key: '$_otpkPrefix${idx}_public',
        value: base64Encode(Uint8List.fromList(otpkPublic.asTypedList)),
      );

      newPrekeys.add({
        'key_id': idx,
        'public_key': base64Encode(Uint8List.fromList(otpkPublic.asTypedList)),
      });
    }

    await _secureStorage.write(
      key: _otpkCount,
      value: (currentCount + count).toString(),
    );

    try {
      await _apiService.post(
        '/encryption/keys/replenish/',
        body: {
          'crypto_version': cryptoVersion,
          'one_time_prekeys': newPrekeys,
        },
      );
      debugPrint('[CryptoService] Replenished $count prekeys');
    } catch (e) {
      debugPrint('[CryptoService] Replenish upload error: $e');
    }
  }

  // ============================================================
  // WIPE (logout/account delete)
  // ============================================================

  /// Securely delete all keys from device.
  Future<void> wipeAllKeys() async {
    final allKeys = await _secureStorage.readAll();
    for (final key in allKeys.keys) {
      if (key.startsWith(_storagePrefix)) {
        await _secureStorage.delete(key: key);
      }
    }
    debugPrint('[CryptoService] All keys wiped');
  }

  // ============================================================
  // PRIVATE HELPERS
  // ============================================================

  Future<Map<String, dynamic>> _rebuildPublicBundle() async {
    final identityPub = await _secureStorage.read(key: _identityPublicKey);
    final identityDhPub = await _secureStorage.read(key: _identityDhPublicKey);
    final spkPub = await _secureStorage.read(key: _signedPreKeyPublic);
    final spkSig = await _secureStorage.read(key: _signedPreKeySignature);
    final spkTs = await _secureStorage.read(key: _signedPreKeyTimestamp);

    final countStr = await _secureStorage.read(key: _otpkCount);
    final count = int.tryParse(countStr ?? '0') ?? 0;

    final List<String> otpkPublics = [];
    for (int i = 0; i < count; i++) {
      final pub = await _secureStorage.read(key: '$_otpkPrefix${i}_public');
      if (pub != null) otpkPublics.add(pub);
    }

    return {
      'crypto_version': cryptoVersion,
      'identity_key_public': identityPub,
      'identity_dh_key_public': identityDhPub,
      'signed_prekey_public': spkPub,
      'signed_prekey_signature': spkSig,
      'signed_prekey_timestamp': int.parse(spkTs ?? '0'),
      'one_time_prekeys': otpkPublics,
    };
  }

  Uint8List _int64ToBytes(int value) {
    final data = ByteData(8);
    data.setInt64(0, value);
    return data.buffer.asUint8List();
  }
}
