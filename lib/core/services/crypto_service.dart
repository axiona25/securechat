import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pinenacl/ed25519.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'session_manager.dart';

/// Result of E2E key initialization. No automatic key regeneration when server already has a bundle.
enum CryptoInitResult {
  /// Local private keys found in Keychain; device provisioned, no upload.
  loadedFromKeychain,
  /// No local keys and server had no bundle; new bundle generated and uploaded.
  generatedAndUploaded,
  /// No local keys but server already has a bundle — do not overwrite; manual recovery required.
  needsManualRecovery,
  /// Initialization failed (e.g. network error).
  error,
}

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
  static const String _keysOwnerUserId = '${_storagePrefix}keys_owner_user_id';

  /// SharedPreferences key for "needs manual recovery" (local keys missing but server has bundle).
  static const String _prefNeedsManualRecovery = 'e2e_needs_manual_recovery';

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
              iOptions: const IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
                accountName: 'com.axphone.app.e2e',
                groupId: 'F28CW3467A.com.axphone.app.e2e',
              ),
            );

  // ============================================================
  // KEY GENERATION
  // ============================================================

  /// Generate complete key bundle and store private keys securely.
  /// Call this once at registration or first login.
  Future<Map<String, dynamic>> generateAndStoreKeyBundle() async {
    debugPrint('[KeychainAudit] generate bundle invoked from generateAndStoreKeyBundle');
    debugPrint('[CryptoService] generateAndStoreKeyBundle START');
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

    // Salva anche l'owner userId
    final ownerPrefs = await SharedPreferences.getInstance();
    final ownerId = ownerPrefs.getInt('current_user_id') ?? 0;
    if (ownerId > 0) {
      await _secureStorage.write(key: _keysOwnerUserId, value: ownerId.toString());
    }

    debugPrint('[CryptoService] generateAndStoreKeyBundle SUCCESS');
    // 7. Return public bundle for upload
    return {
      'crypto_version': cryptoVersion,
      'identity_key_public': base64Encode(identityPublic),
      'identity_dh_key_public': base64Encode(Uint8List.fromList(identityDhPublic.asTypedList)),
      'signed_prekey_public': base64Encode(Uint8List.fromList(signedPreKeyPublic.asTypedList)),
      'signed_prekey_signature': base64Encode(signature),
      'signed_prekey_timestamp': timestamp,
      'one_time_prekeys': oneTimePreKeys.asMap().entries.map((e) => {
            'key_id': e.key,
            'public_key': base64Encode(e.value['public']!),
          }).toList(),
    };
  }

  // ============================================================
  // KEY UPLOAD
  // ============================================================

  /// Upload public key bundle to server.
  /// Call after generateAndStoreKeyBundle() or _rebuildPublicBundle().
  /// [resetOtp] when true (default) calls reset-otp before upload; pass false when re-uploading after rebuild to avoid clearing OTPs.
  Future<bool> uploadKeyBundle(Map<String, dynamic> publicBundle, {bool resetOtp = true}) async {
    print('[CryptoDebug] uploadKeyBundle called');
    try {
      if (resetOtp) {
        await _apiService.post(
          '/encryption/keys/reset-otp/',
          body: {},
          requiresAuth: true,
        );
      }
      debugPrint('[CryptoService] uploadKeyBundle START - keys: ${publicBundle.keys.toList()}');
      await _apiService.post(
        '/encryption/keys/upload/',
        body: publicBundle,
      );
      await _secureStorage.write(key: _keysUploaded, value: 'true');
      debugPrint('[CryptoService] uploadKeyBundle SUCCESS');
      print('[CryptoDebug] uploadKeyBundle result=true');
      return true;
    } on ApiException catch (e) {
      debugPrint('[CryptoService] uploadKeyBundle FAILED: $e');
      print('[CryptoDebug] uploadKeyBundle result=false');
      return false;
    } catch (e) {
      debugPrint('[CryptoService] uploadKeyBundle FAILED: $e');
      print('[CryptoDebug] uploadKeyBundle result=false');
      return false;
    }
  }

  /// Initialize E2E keys.
  /// 1) If private keys exist in Keychain → load and consider device provisioned.
  /// 2) If no local keys and server has NO bundle → generate new bundle, save to Keychain, upload.
  /// 3) If no local keys but server HAS bundle → auto-reset server bundle, generate fresh keys, upload.
  Future<CryptoInitResult> initializeKeys() async {
    try {
      // Rileva reinstallazione: UserDefaults viene cancellato
      // dalla disinstallazione, il Keychain no.
      final prefs = await SharedPreferences.getInstance();
      final appInstalled = prefs.getBool('app_installed') ?? false;
      if (!appInstalled) {
        final hasKeys = await _secureStorage.read(key: _identityPrivateKey) != null;
        if (!hasKeys) {
          await _secureStorage.deleteAll();
          debugPrint('[CryptoBootstrap] First install: Keychain cleared (no existing keys)');
        } else {
          debugPrint('[CryptoBootstrap] app_installed=false but keys already exist — skipping deleteAll');
        }
        await prefs.setBool('app_installed', true);
      }

      // Controlla se le chiavi nel Keychain appartengono a un utente diverso
      final prefs2 = await SharedPreferences.getInstance();
      final currentUserId = prefs2.getInt('current_user_id') ?? 0;
      if (currentUserId > 0) {
        final savedOwner = await _secureStorage.read(key: _keysOwnerUserId);
        final savedOwnerInt = int.tryParse(savedOwner ?? '') ?? 0;
        if (savedOwnerInt > 0 && savedOwnerInt != currentUserId) {
          debugPrint('[CryptoBootstrap] KEY OWNER MISMATCH: keychain owner=$savedOwnerInt current=$currentUserId — wiping keys');
          await _secureStorage.deleteAll();
          debugPrint('[CryptoBootstrap] Keychain wiped for user change');
        }
        // Salva/aggiorna l'owner corrente
        await _secureStorage.write(key: _keysOwnerUserId, value: currentUserId.toString());
      }

      await _keychainAuditLog();

      await _migrateKeysFromSharedPreferencesIfNeeded();

      bool identityPrivate = await _secureStorage.read(key: _identityPrivateKey) != null;
      bool identityDhPrivate = await _secureStorage.read(key: _identityDhPrivateKey) != null;
      bool signedPrekeyPrivate = await _secureStorage.read(key: _signedPreKeyPrivate) != null;
      bool localKeysFound = identityPrivate && identityDhPrivate && signedPrekeyPrivate;

      debugPrint('[CryptoBootstrap] keyCheck identityPrivate=$identityPrivate');
      debugPrint('[CryptoBootstrap] keyCheck identityDhPrivate=$identityDhPrivate');
      debugPrint('[CryptoBootstrap] keyCheck signedPrekeyPrivate=$signedPrekeyPrivate');
      debugPrint('[CryptoBootstrap] localKeysFound=$localKeysFound (false => any of the three reads above returned null)');

      if (!localKeysFound) {
        await _logLegacyPrefsCheck();
        debugPrint('[CryptoBootstrap] retry_local_key_read=true');
        identityPrivate = await _secureStorage.read(key: _identityPrivateKey) != null;
        identityDhPrivate = await _secureStorage.read(key: _identityDhPrivateKey) != null;
        signedPrekeyPrivate = await _secureStorage.read(key: _signedPreKeyPrivate) != null;
        localKeysFound = identityPrivate && identityDhPrivate && signedPrekeyPrivate;
        debugPrint('[CryptoBootstrap] retry_keyCheck identityPrivate=$identityPrivate');
        debugPrint('[CryptoBootstrap] retry_keyCheck identityDhPrivate=$identityDhPrivate');
        debugPrint('[CryptoBootstrap] retry_keyCheck signedPrekeyPrivate=$signedPrekeyPrivate');
        debugPrint('[CryptoBootstrap] localKeysFoundAfterRetry=$localKeysFound');
      }

      final serverBundleResult = await _verifyKeysOnServer();
      if (serverBundleResult == null) {
        debugPrint('[CryptoBootstrap] serverBundleCheck=error');
        debugPrint('[CryptoBootstrap] reason=transient_server_check_failure');
        debugPrint('[CryptoBootstrap] action=manual_recovery_due_to_server_check_error');
        await _setNeedsManualRecoveryFlag();
        return CryptoInitResult.needsManualRecovery;
      }
      final serverBundleExists = serverBundleResult;
      debugPrint('[CryptoBootstrap] serverBundleCheck=${serverBundleExists ? 'present' : 'absent'}');
      debugPrint('[CryptoBootstrap] serverBundleExists=$serverBundleExists');

      if (localKeysFound) {
        final localSpkTsStr = await _secureStorage.read(key: _signedPreKeyTimestamp);
        final localSpkTs = int.tryParse(localSpkTsStr ?? '') ?? 0;
        final serverMeta = await _getServerBundleMeta();
        final serverSpkTs = serverMeta?['signed_prekey_timestamp'];
        final serverTs = serverSpkTs is int ? serverSpkTs : (serverSpkTs is num ? serverSpkTs.toInt() : null);
        final aligned = serverTs != null && localSpkTs != 0 && serverTs == localSpkTs;
        print('[CryptoDebug] localSpkTs=$localSpkTs serverTs=$serverTs aligned=$aligned');
        final forceReupload = await _secureStorage.read(key: '${_storagePrefix}force_reupload') == 'true';
        if (!forceReupload && aligned) {
          print('[CryptoBootstrap] action=load_local_keys (skip upload, server aligned with local signed_prekey_timestamp)');
          await _clearNeedsManualRecoveryFlag();
          _initialized = true;
          return CryptoInitResult.loadedFromKeychain;
        }
        await _secureStorage.delete(key: '${_storagePrefix}force_reupload');
        final publicBundle = await _rebuildPublicBundle();
        await uploadKeyBundle(publicBundle, resetOtp: false);
        await _secureStorage.write(key: _keysUploaded, value: 'true');
        await _clearNeedsManualRecoveryFlag();
        _initialized = true;
        return CryptoInitResult.loadedFromKeychain;
      }

      if (serverBundleExists) {
        debugPrint('[CryptoBootstrap] action=auto_reset (local keys missing, server has bundle — auto-regenerate)');
        try {
          await _apiService.postLog(
            '[E2E-AUTO-RESET] local keys missing, server bundle exists — auto-resetting for user',
          );
        } catch (_) {}
        try {
          await _apiService.post('/encryption/reset/', body: <String, dynamic>{});
          debugPrint('[CryptoBootstrap] server bundle reset OK — generating new keys');
        } catch (e) {
          debugPrint('[CryptoBootstrap] server bundle reset failed: $e — generating anyway');
        }
        final publicBundle = await generateAndStoreKeyBundle();
        final uploaded = await uploadKeyBundle(publicBundle);
        await _clearNeedsManualRecoveryFlag();
        if (uploaded) {
          _initialized = true;
          return CryptoInitResult.generatedAndUploaded;
        }
        return CryptoInitResult.error;
      }

      debugPrint('[CryptoBootstrap] action=generate_new_bundle');
      final publicBundle = await generateAndStoreKeyBundle();
      final uploaded = await uploadKeyBundle(publicBundle);
      await _clearNeedsManualRecoveryFlag();
      if (uploaded) {
        _initialized = true;
        return CryptoInitResult.generatedAndUploaded;
      }
      return CryptoInitResult.error;
    } catch (e) {
      debugPrint('[CryptoBootstrap] initializeKeys error: $e');
      return CryptoInitResult.error;
    }
  }

  Future<void> _setNeedsManualRecoveryFlag() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefNeedsManualRecovery, true);
  }

  Future<void> _clearNeedsManualRecoveryFlag() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefNeedsManualRecovery);
  }

  /// True if local E2E keys are missing but server already has a bundle (e.g. after reinstall on same device).
  static Future<bool> getNeedsManualRecoveryFlag() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefNeedsManualRecovery) ?? false;
  }

  /// Clear the needs-manual-recovery flag (e.g. after explicit manual reset).
  static Future<void> clearNeedsManualRecoveryFlag() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefNeedsManualRecovery);
  }

  /// Ensures E2E keys exist locally and on server. Call after each login.
  /// 1) If local keys missing (getIdentityPublicKey null) → hardResetE2E, return 'regenerated'.
  /// 2) If server has no bundle (_verifyKeysOnServer false) → hardResetE2E, return 'regenerated'.
  /// 3) If both present → return 'ok'. On error, logs and returns 'error' (does not block login).
  Future<String> ensureE2EReady() async {
    try {
      // 1. Check if keys are present in local Keychain
      final identityPub = await getIdentityPublicKey();
      if (identityPub == null) {
        await hardResetE2E();
        debugPrint('[E2E] Chiavi rigenerate automaticamente');
        return 'regenerated';
      }
      // 2. Check if server has this user's keys
      final serverHasKeys = await _verifyKeysOnServer();
      if (serverHasKeys == false) {
        await hardResetE2E();
        debugPrint('[E2E] Chiavi rigenerate automaticamente');
        return 'regenerated';
      }
      if (serverHasKeys == null) {
        debugPrint('[E2E] Verifica chiavi server non disponibile (transient), considero OK');
        return 'ok';
      }
      // 4. Keys present both locally and on server
      debugPrint('[E2E] Chiavi OK');
      return 'ok';
    } catch (e) {
      debugPrint('[E2E] ensureE2EReady failed: $e');
      return 'error';
    }
  }

  /// Diagnostic audit: log Keychain read state and config so we can see why localKeysFound is false after reinstall.
  Future<void> _keychainAuditLog() async {
    const accountName = 'com.axphone.app.e2e';
    const accessibility = 'KeychainAccessibility.first_unlock_this_device';
    debugPrint('[KeychainAudit] secure storage options = accountName: $accountName, accessibility: $accessibility');
    String bundleId = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      bundleId = info.packageName;
      debugPrint('[KeychainAudit] bundle id = $bundleId');
    } catch (e) {
      debugPrint('[KeychainAudit] bundle id = (failed: $e)');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedInstallId = prefs.getString('e2e_install_id');
      final buildNumber = (await PackageInfo.fromPlatform()).buildNumber;
      if (storedInstallId != null && storedInstallId != buildNumber) {
        debugPrint('[KeychainAudit] install phase = first launch after update/reinstall (stored: $storedInstallId, current: $buildNumber)');
      } else if (storedInstallId == null) {
        debugPrint('[KeychainAudit] install phase = first launch (no stored install id)');
      } else {
        debugPrint('[KeychainAudit] install phase = normal launch (same build $buildNumber)');
      }
    } catch (_) {
      debugPrint('[KeychainAudit] install phase = (could not determine)');
    }

    final idPriv = await _secureStorage.read(key: _identityPrivateKey);
    final idDhPriv = await _secureStorage.read(key: _identityDhPrivateKey);
    final spkPriv = await _secureStorage.read(key: _signedPreKeyPrivate);
    debugPrint('[KeychainAudit] reading identityPrivate -> ${idPriv != null ? "present" : "absent"}');
    debugPrint('[KeychainAudit] reading identityDhPrivate -> ${idDhPriv != null ? "present" : "absent"}');
    debugPrint('[KeychainAudit] reading signedPrekeyPrivate -> ${spkPriv != null ? "present" : "absent"}');
    final wouldBeFound = idPriv != null && idDhPriv != null && spkPriv != null;
    if (!wouldBeFound) {
      final missing = <String>[];
      if (idPriv == null) missing.add('identityPrivate');
      if (idDhPriv == null) missing.add('identityDhPrivate');
      if (spkPriv == null) missing.add('signedPrekeyPrivate');
      debugPrint('[KeychainAudit] localKeysFound will be false because missing in Keychain: ${missing.join(", ")}');
    }
  }

  /// Migrate E2E keys from SharedPreferences to Keychain only after read-back and final critical-key check.
  /// Removes from prefs only when each key's read-back matches AND the three critical keys are readable after the loop.
  Future<void> _migrateKeysFromSharedPreferencesIfNeeded() async {
    final hasInKeychain = await _secureStorage.read(key: _identityPrivateKey) != null;
    if (hasInKeychain) return;

    await _keychainHealthCheck();

    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_storagePrefix)).toList();
    if (keys.isEmpty) return;

    final verifiedKeys = <String>[];
    int failed = 0;
    for (final k in keys) {
      final value = prefs.getString(k);
      if (value == null || value.isEmpty) continue;
      try {
        await _secureStorage.write(key: k, value: value);
        debugPrint('[Migration] wrote key $k to keychain');
        final readBack = await _secureStorage.read(key: k);
        if (readBack == value) {
          verifiedKeys.add(k);
          debugPrint('[Migration] verified key $k from keychain');
        } else {
          failed++;
          debugPrint('[Migration] retained legacy key $k because verification failed (read-back mismatch)');
        }
      } catch (e) {
        failed++;
        debugPrint('[Migration] retained legacy key $k because verification failed: $e');
      }
    }

    // Final check: ensure the three critical keys are readable (same read path as initializeKeys).
    // Avoids removing from prefs if Keychain only served from cache and real persist failed.
    final criticalReadable = (await _secureStorage.read(key: _identityPrivateKey) != null) &&
        (await _secureStorage.read(key: _identityDhPrivateKey) != null) &&
        (await _secureStorage.read(key: _signedPreKeyPrivate) != null);
    if (criticalReadable && verifiedKeys.isNotEmpty) {
      for (final k in verifiedKeys) {
        await prefs.remove(k);
      }
      debugPrint('[CryptoService] Keys migrated from SharedPreferences to Keychain: ${verifiedKeys.length} keys');
    } else if (verifiedKeys.isNotEmpty) {
      debugPrint('[CryptoService] Migration not committed: critical keys not readable after write (prefs retained)');
    }
    if (failed > 0) {
      debugPrint('[CryptoService] Migration left $failed legacy keys in prefs (keychain verify failed)');
    }
  }

  /// Log whether SharedPreferences still contains legacy E2E keys (when local Keychain has none).
  Future<void> _logLegacyPrefsCheck() async {
    final prefs = await SharedPreferences.getInstance();
    final prefsIdentityPrivate = prefs.getString(_identityPrivateKey) != null;
    final prefsIdentityDhPrivate = prefs.getString(_identityDhPrivateKey) != null;
    final prefsSignedPrekeyPrivate = prefs.getString(_signedPreKeyPrivate) != null;
    debugPrint('[LegacyCheck] prefs identityPrivate=$prefsIdentityPrivate');
    debugPrint('[LegacyCheck] prefs identityDhPrivate=$prefsIdentityDhPrivate');
    debugPrint('[LegacyCheck] prefs signedPrekeyPrivate=$prefsSignedPrekeyPrivate');
  }

  /// Quick healthcheck: write/read/delete a temp key to ensure Keychain is working.
  Future<void> _keychainHealthCheck() async {
    const String tempKey = '${_storagePrefix}_keychain_health_check';
    try {
      await _secureStorage.write(key: tempKey, value: 'ok');
      debugPrint('[KeychainHealth] write temp ok');
      final read = await _secureStorage.read(key: tempKey);
      if (read == 'ok') {
        debugPrint('[KeychainHealth] read temp ok');
      } else {
        debugPrint('[KeychainHealth] read temp mismatch: got ${read != null ? "non-null" : "null"}');
      }
      await _secureStorage.delete(key: tempKey);
      debugPrint('[KeychainHealth] delete temp ok');
    } catch (e) {
      debugPrint('[KeychainHealth] healthcheck failed: $e');
    }
  }

  /// Returns true if server has bundle, false if server has no bundle, null if check failed (transient).
  Future<bool?> _verifyKeysOnServer() async {
    try {
      final data = await _apiService.get('/encryption/keys/count/');
      final hasBundle = data['has_key_bundle'] == true;
      final preKeyCount = data['available_prekeys'] ?? 0;
      debugPrint('[CryptoService] serverHasKeys: hasBundle=$hasBundle, prekeys=$preKeyCount');
      return hasBundle;
    } catch (e) {
      debugPrint('[CryptoService] _verifyKeysOnServer error: $e');
      return null; // caller logs [CryptoBootstrap] serverBundleCheck=error
    }
  }

  /// Fetches current user's bundle metadata from GET /encryption/keys/me/ for alignment check.
  /// Returns map with uploaded_at (String iso), signed_prekey_timestamp (int); null on error or 404.
  Future<Map<String, dynamic>?> _getServerBundleMeta() async {
    try {
      final response = await _apiService.get('/encryption/keys/me/');
      return response is Map<String, dynamic> ? response : null;
    } catch (e) {
      debugPrint('[CryptoService] _getServerBundleMeta: $e');
      return null;
    }
  }

  /// Returns server bundle uploaded_at as DateTime, or null.
  Future<DateTime?> _getServerBundleUploadedAt() async {
    final meta = await _getServerBundleMeta();
    final uploadedAt = meta?['uploaded_at'];
    if (uploadedAt != null) {
      return DateTime.tryParse(uploadedAt.toString());
    }
    return null;
  }

  /// Fetch remote user's key bundle from server (no local storage).
  /// Used to force refresh before opening chat so encrypt uses up-to-date keys.
  Future<void> prefetchKeyBundle(int userId) async {
    try {
      await _apiService.get('/encryption/keys/$userId/');
    } catch (e) {
      debugPrint('[CryptoService] prefetchKeyBundle error: $e');
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
  /// Consumes the key: reads it and deletes it from storage (forward secrecy).
  /// Returns null if none stored. Used when decrypting first message without otpKeyId in header.
  Future<Uint8List?> getFirstAvailableOneTimePreKeyPrivate() async {
    final countStr = await _secureStorage.read(key: _otpkCount);
    final count = int.tryParse(countStr ?? '0') ?? 0;
    for (int i = 0; i < count && i < 100; i++) {
      final b64 = await _secureStorage.read(key: '$_otpkPrefix${i}_private');
      if (b64 != null) {
        await deleteOneTimePreKey(i);
        return base64Decode(b64);
      }
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

  /// Hard reset E2E: clear local + server, then generate and upload new bundle (test/recovery).
  /// Order: clear flag, clear sessions, wipe keys, POST server reset, generate, save, upload, clear flag.
  Future<void> hardResetE2E() async {
    debugPrint('[E2E-Reset] hard reset started');
    try {
      await clearNeedsManualRecoveryFlag();
      await SessionManager().clearAllSessions();
      debugPrint('[E2E-Reset] local sessions cleared');
      await wipeAllKeys();
      debugPrint('[E2E-Reset] local keys wiped');
      try {
        await _apiService.post('/encryption/reset/', body: <String, dynamic>{});
        debugPrint('[E2E-Reset] server reset completed');
      } on ApiException catch (e) {
        debugPrint('[E2E-Reset] step 4 failed (server reset) status=${e.statusCode} body=${e.message}');
        rethrow;
      } catch (e) {
        debugPrint('[E2E-Reset] step 4 failed (server reset): $e');
        rethrow;
      }
      Map<String, dynamic> publicBundle;
      try {
        publicBundle = await generateAndStoreKeyBundle();
        debugPrint('[E2E-Reset] new bundle generated');
      } catch (e) {
        debugPrint('[E2E-Reset] generateAndStoreKeyBundle failed: $e');
        rethrow;
      }
      final uploaded = await uploadKeyBundle(publicBundle);
      if (!uploaded) {
        debugPrint('[E2E-Reset] uploadKeyBundle failed (upload new bundle)');
        throw Exception('Upload nuovo bundle fallito');
      }
      debugPrint('[E2E-Reset] new bundle uploaded');
      await clearNeedsManualRecoveryFlag();
      debugPrint('[E2E-Reset] local+server reset completed');
    } catch (e, st) {
      debugPrint('[E2E-Reset] failed: $e');
      debugPrint('[E2E-Reset] stack: $st');
      rethrow;
    }
  }

  /// Force re-upload of public bundle on next initializeKeys() (e.g. after login when sessions were cleared).
  Future<void> forceReuploadOnNextInit() async {
    await _secureStorage.write(key: '${_storagePrefix}force_reupload', value: 'true');
  }

  /// Securely delete all keys from device.
  Future<void> wipeAllKeys() async {
    debugPrint('[KeychainAudit] wipe invoked from CryptoService.wipeAllKeys');
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

    final List<Map<String, dynamic>> oneTimePrekeys = [];
    for (int i = 0; i < count; i++) {
      final pub = await _secureStorage.read(key: '$_otpkPrefix${i}_public');
      if (pub != null) {
        oneTimePrekeys.add({'key_id': i, 'public_key': pub});
      }
    }

    return {
      'crypto_version': cryptoVersion,
      'identity_key_public': identityPub,
      'identity_dh_key_public': identityDhPub,
      'signed_prekey_public': spkPub,
      'signed_prekey_signature': spkSig,
      'signed_prekey_timestamp': int.parse(spkTs ?? '0'),
      'one_time_prekeys': oneTimePrekeys,
    };
  }

  Uint8List _int64ToBytes(int value) {
    final data = ByteData(8);
    data.setInt64(0, value);
    return data.buffer.asUint8List();
  }
}
