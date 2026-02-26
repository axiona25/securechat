import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pinenacl/ed25519.dart';
import 'package:pinenacl/tweetnacl.dart';
import 'package:pinenacl/x25519.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'crypto_service.dart';

/// Manages E2E encryption sessions between users.
/// Each pair of users has one session (identified by the other user's ID).
class SessionManager {
  static const String _sessionPrefix = 'scp_session_';
  static const String _cachePrefix = 'scp_msg_cache_';
  static const String _failedPrefix = 'e2e_failed_';

  final FlutterSecureStorage _secureStorage;
  final ApiService _apiService;
  final CryptoService _cryptoService;

  final Map<int, _DoubleRatchetSession> _sessions = {};

  /// Cache of plaintext for messages we sent (messageId → plaintext).
  final Map<String, String> _sentMessagePlaintexts = {};
  final Map<String, bool> _failedDecryptCache = {};
  /// Log Cache MISS only once per messageId to avoid console flooding.
  final Set<String> _loggedCacheMisses = {};

  SessionManager({
    required ApiService apiService,
    required CryptoService cryptoService,
    FlutterSecureStorage? secureStorage,
  })  : _apiService = apiService,
        _cryptoService = cryptoService,
        _secureStorage = secureStorage ??
            FlutterSecureStorage(
              aOptions: const AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  /// Ensure we have an active session with the given user (for sending).
  /// If no session exists, performs X3DH handshake and initializes Double Ratchet.
  Future<_DoubleRatchetSession> _getOrCreateSession(int otherUserId) async {
    if (_sessions.containsKey(otherUserId)) {
      return _sessions[otherUserId]!;
    }

    final stored = await _secureStorage.read(key: '$_sessionPrefix$otherUserId');
    if (stored != null) {
      try {
        final session = _DoubleRatchetSession.fromJson(jsonDecode(stored) as Map<String, dynamic>);
        _sessions[otherUserId] = session;
        debugPrint('[SessionManager] Loaded existing session for user $otherUserId');
        return session;
      } catch (e) {
        debugPrint('[SessionManager] Failed to load session: $e, creating new one');
      }
    }

    debugPrint('[SessionManager] No session for user $otherUserId, performing X3DH...');
    final session = await _performX3DHAndInitSession(otherUserId);
    _sessions[otherUserId] = session;
    await _saveSession(otherUserId, session);
    return session;
  }

  /// Cache the plaintext of a message (sent or decrypted) — persists to disk.
  Future<void> cacheSentMessage(String messageId, String plaintext) async {
    _sentMessagePlaintexts[messageId] = plaintext;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_cachePrefix$messageId', plaintext);
    final verify = prefs.getString('$_cachePrefix$messageId');
    debugPrint('[SessionManager] Cached plaintext for message $messageId (verified: ${verify != null})');
  }

  /// Get cached plaintext for a message. Checks memory first, then disk.
  Future<String?> getCachedPlaintext(String messageId) async {
    final mem = _sentMessagePlaintexts[messageId];
    if (mem != null) return mem;
    final prefs = await SharedPreferences.getInstance();
    final disk = prefs.getString('$_cachePrefix$messageId');
    if (disk != null) {
      _sentMessagePlaintexts[messageId] = disk;
      return disk;
    }
    if (_loggedCacheMisses.add(messageId)) {
      debugPrint('[SessionManager] Cache MISS for $messageId');
    }
    return null;
  }

  /// Mark a message as decrypt-failed (persisted) so we don't retry.
  Future<void> markDecryptFailed(String messageId) async {
    _failedDecryptCache[messageId] = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_failedPrefix$messageId', true);
    } catch (_) {}
  }

  /// Check if a message is known to have failed decrypt (memory or disk).
  Future<bool> isDecryptFailed(String messageId) async {
    if (_failedDecryptCache.containsKey(messageId)) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final failed = prefs.getBool('$_failedPrefix$messageId') ?? false;
      if (failed) _failedDecryptCache[messageId] = true;
      return failed;
    } catch (_) {
      return false;
    }
  }

  /// Check if a message is in our cache (memory or disk).
  Future<bool> hasCachedPlaintext(String messageId) async {
    if (_sentMessagePlaintexts.containsKey(messageId)) return true;
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$_cachePrefix$messageId');
  }

  /// Parses a decrypted message that may be an attachment payload (JSON with type, file_key_b64, caption).
  /// Returns null if not an attachment payload; otherwise returns map with 'file_key_b64' and 'caption'.
  /// Used so the file key is carried in a single Double Ratchet message (one step) instead of separate steps.
  static Map<String, dynamic>? parseAttachmentPayload(String plaintext) {
    try {
      final trimmed = plaintext.trim();
      if (trimmed.isEmpty || !trimmed.startsWith('{')) return null;
      final m = jsonDecode(plaintext) as Map<String, dynamic>?;
      if (m == null || m['type']?.toString() != 'attachment') return null;
      final fileKey = m['file_key_b64']?.toString();
      final caption = m['caption']?.toString() ?? '';
      if (fileKey == null || fileKey.isEmpty) return null;
      return {'file_key_b64': fileKey, 'caption': caption};
    } catch (_) {
      return null;
    }
  }

  /// Parses decrypted content as location payload (JSON with type: 'location', lat, lng, address).
  static Map<String, dynamic>? parseLocationPayload(String plaintext) {
    try {
      final trimmed = plaintext.trim();
      if (trimmed.isEmpty || !trimmed.startsWith('{')) return null;
      final m = jsonDecode(plaintext) as Map<String, dynamic>?;
      if (m == null || m['type']?.toString() != 'location') return null;
      final lat = m['lat'];
      final lng = m['lng'];
      if (lat == null || lng == null) return null;
      return {
        'lat': lat is num ? lat.toDouble() : double.tryParse(lat.toString()),
        'lng': lng is num ? lng.toDouble() : double.tryParse(lng.toString()),
        'address': m['address']?.toString() ?? '',
      };
    } catch (_) {
      return null;
    }
  }

  /// Parses decrypted content as contact payload (JSON with type: 'contact', name, phone, email).
  static Map<String, dynamic>? parseContactPayload(String plaintext) {
    try {
      final trimmed = plaintext.trim();
      if (trimmed.isEmpty || !trimmed.startsWith('{')) return null;
      final m = jsonDecode(plaintext) as Map<String, dynamic>?;
      if (m == null || m['type']?.toString() != 'contact') return null;
      return {
        'name': m['name']?.toString() ?? '',
        'phone': m['phone']?.toString() ?? '',
        'email': m['email']?.toString() ?? '',
      };
    } catch (_) {
      return null;
    }
  }

  /// Encrypt a plaintext message for a specific user.
  /// Returns the complete wire-format payload (ready to base64-encode and send).
  Future<Uint8List> encryptMessage(int otherUserId, String plaintext) async {
    final session = await _getOrCreateSession(otherUserId);
    final plaintextBytes = Uint8List.fromList(utf8.encode(plaintext));
    final encrypted = session.encrypt(plaintextBytes);
    final header = encrypted['header'] as Uint8List;
    final ciphertext = encrypted['ciphertext'] as Uint8List;
    final headerLen = header.length;
    final combined = Uint8List.fromList([
      (headerLen >> 8) & 0xFF,
      headerLen & 0xFF,
      ...header,
      ...ciphertext,
    ]);
    await _saveSession(otherUserId, session);
    debugPrint('[SessionManager] Message encrypted for user $otherUserId (${combined.length} bytes)');
    return combined;
  }

  /// Decrypt a received message from a specific user.
  /// [combinedPayload] is the full wire format: [2B headerLen][header][nonce+ciphertext].
  Future<String> decryptMessage(int senderUserId, Uint8List combinedPayload) async {
    if (combinedPayload.length < 3) {
      throw Exception('Message too short');
    }
    final headerLen = (combinedPayload[0] << 8) | combinedPayload[1];
    if (combinedPayload.length < 2 + headerLen + 1) {
      throw Exception('Invalid header length');
    }
    final header = Uint8List.fromList(combinedPayload.sublist(2, 2 + headerLen));
    final encryptedPayload = Uint8List.fromList(combinedPayload.sublist(2 + headerLen));

    debugPrint(
      '[SessionManager] decryptMessage from user $senderUserId, headerLen=$headerLen, payloadLen=${encryptedPayload.length}',
    );

    final parsedHeader = _DoubleRatchetSession.parseHeader(header);
    final isInitial = parsedHeader['isInitial'] as bool;

    _DoubleRatchetSession session;

    if (_sessions.containsKey(senderUserId)) {
      session = _sessions[senderUserId]!;
      debugPrint('[SessionManager] Using existing session for user $senderUserId');
    } else {
      final stored = await _secureStorage.read(key: '$_sessionPrefix$senderUserId');
      if (stored != null) {
        try {
          session = _DoubleRatchetSession.fromJson(jsonDecode(stored) as Map<String, dynamic>);
          _sessions[senderUserId] = session;
          debugPrint('[SessionManager] Loaded session from storage for user $senderUserId');
        } catch (e) {
          debugPrint('[SessionManager] Failed to load session: $e');
          if (!isInitial) {
            throw Exception('No session and not an initial message — cannot decrypt');
          }
          session = await _createReceiverSession(senderUserId, parsedHeader);
          _sessions[senderUserId] = session;
        }
      } else if (isInitial) {
        debugPrint('[SessionManager] Creating receiver session from initial message');
        session = await _createReceiverSession(senderUserId, parsedHeader);
        _sessions[senderUserId] = session;
      } else {
        throw Exception('No session exists and message is not initial — cannot decrypt');
      }
    }

    // Backup state from storage before decrypt — on failure we rollback to avoid ratchet corruption
    final backupJson = await _secureStorage.read(key: '$_sessionPrefix$senderUserId');

    try {
      final plaintext = session.decrypt(encryptedPayload, header);
      await _saveSession(senderUserId, session);
      final result = utf8.decode(plaintext);
      debugPrint(
        '[SessionManager] Decrypted message from user $senderUserId: "${result.substring(0, result.length.clamp(0, 20))}..."',
      );
      return result;
    } catch (e) {
      if (backupJson != null) {
        try {
          _sessions[senderUserId] =
              _DoubleRatchetSession.fromJson(jsonDecode(backupJson) as Map<String, dynamic>);
          debugPrint('[SessionManager] Rolled back session for user $senderUserId after decrypt failure');
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// Create a receiver session from an initial X3DH message (receiver-side X3DH).
  Future<_DoubleRatchetSession> _createReceiverSession(
    int senderUserId,
    Map<String, dynamic> parsedHeader,
  ) async {
    try {
      debugPrint('[X3DH-RX] Starting receiver session for sender $senderUserId');
      final ephemeralRaw = parsedHeader['ephemeralPublic'];
      final identityRaw = parsedHeader['identityDhPublic'];
      final dhPublicRaw = parsedHeader['dhPublic'];

      if (ephemeralRaw == null || identityRaw == null || dhPublicRaw == null) {
        throw Exception('Initial message missing X3DH metadata (ephemeral or identity key)');
      }

      final senderEphemeralPub = ephemeralRaw is Uint8List
          ? ephemeralRaw
          : Uint8List.fromList(ephemeralRaw as List<int>);
      final senderIdentityDhPub = identityRaw is Uint8List
          ? identityRaw
          : Uint8List.fromList(identityRaw as List<int>);
      final senderDhPublic = dhPublicRaw is Uint8List
          ? dhPublicRaw
          : Uint8List.fromList(dhPublicRaw as List<int>);

      debugPrint('[X3DH-RX] Ephemeral key from header: ${senderEphemeralPub.length} bytes');
      debugPrint(
        '[SessionManager] Creating receiver session: sender ephemeral (${senderEphemeralPub.length}B), identity (${senderIdentityDhPub.length}B)',
      );

      final mySignedPreKeyPrivate = await _cryptoService.getSignedPreKeyPrivate();
      final myIdentityDhPrivate = await _cryptoService.getIdentityDhPrivateKey();
      final mySignedPreKeyPublic = await _cryptoService.getSignedPreKeyPublic();

      if (mySignedPreKeyPrivate == null || myIdentityDhPrivate == null || mySignedPreKeyPublic == null) {
        throw Exception('Missing own keys for receiver X3DH');
      }
      debugPrint('[X3DH-RX] Own identity key loaded: ${myIdentityDhPrivate != null}');
      debugPrint('[X3DH-RX] Own signed prekey loaded: ${mySignedPreKeyPrivate != null}');
      debugPrint('[SessionManager] Got own keys for receiver X3DH');

      final dh1 = _x25519DH(mySignedPreKeyPrivate, senderIdentityDhPub);
      debugPrint('[X3DH-RX] DH1 done');
      final dh2 = _x25519DH(myIdentityDhPrivate, senderEphemeralPub);
      debugPrint('[X3DH-RX] DH2 done');
      final dh3 = _x25519DH(mySignedPreKeyPrivate, senderEphemeralPub);
      debugPrint('[X3DH-RX] DH3 done');

      Uint8List dhConcat;
      final myOtpPrivate = await _cryptoService.getFirstAvailableOneTimePreKeyPrivate();
      if (myOtpPrivate != null) {
        final dh4 = _x25519DH(myOtpPrivate, senderEphemeralPub);
        dhConcat = Uint8List.fromList([...dh1, ...dh2, ...dh3, ...dh4]);
        debugPrint('[SessionManager] Receiver X3DH: 4 DH operations (with OTP)');
      } else {
        dhConcat = Uint8List.fromList([...dh1, ...dh2, ...dh3]);
        debugPrint('[SessionManager] Receiver X3DH: 3 DH operations (no OTP)');
      }

      final sharedSecret = _hkdfSha512(
        ikm: dhConcat,
        info: utf8.encode('SCP_X3DH_SharedSecret_v1'),
        length: 32,
        salt: Uint8List(32),
      );
      debugPrint('[X3DH-RX] Shared secret derived: ${sharedSecret.length} bytes');
      debugPrint('[SessionManager] Receiver X3DH shared secret derived (${sharedSecret.length} bytes)');

      final session = _DoubleRatchetSession.initReceiver(
        sharedSecret: sharedSecret,
        dhPrivateKey: mySignedPreKeyPrivate,
        dhPublicKey: mySignedPreKeyPublic,
      );
      session.doDhRatchetStep(senderDhPublic);
      await _saveSession(senderUserId, session);
      debugPrint('[SessionManager] Receiver session created and saved for sender $senderUserId');
      return session;
    } catch (e) {
      debugPrint('[X3DH-RX] FAILED: $e');
      rethrow;
    }
  }

  Future<bool> hasSession(int otherUserId) async {
    if (_sessions.containsKey(otherUserId)) return true;
    final stored = await _secureStorage.read(key: '$_sessionPrefix$otherUserId');
    return stored != null;
  }

  Future<void> clearAllSessions() async {
    _sessions.clear();
    _sentMessagePlaintexts.clear();
    final all = await _secureStorage.readAll();
    for (final key in all.keys) {
      if (key.startsWith(_sessionPrefix)) {
        await _secureStorage.delete(key: key);
      }
    }
    debugPrint('[SessionManager] All sessions cleared');
  }

  Future<_DoubleRatchetSession> _performX3DHAndInitSession(int otherUserId) async {
    debugPrint('[SessionManager] Fetching key bundle for user $otherUserId...');
    final bundleResponse = await _apiService.get('/encryption/keys/$otherUserId/');

    final otherIdentityKeyPub = Uint8List.fromList(base64Decode(
      (bundleResponse['identity_key'] ?? bundleResponse['identity_key_public']) as String,
    ));
    final otherIdentityDhPub = Uint8List.fromList(base64Decode(
      (bundleResponse['identity_dh_key'] ?? bundleResponse['identity_dh_key_public']) as String,
    ));
    final otherSignedPreKeyPub = Uint8List.fromList(base64Decode(
      (bundleResponse['signed_prekey'] ?? bundleResponse['signed_prekey_public']) as String,
    ));
    final otherSignedPreKeySig = Uint8List.fromList(base64Decode(
      bundleResponse['signed_prekey_signature'] as String,
    ));
    final otherSignedPreKeyTs = bundleResponse['signed_prekey_timestamp'];
    final ts = otherSignedPreKeyTs is int
        ? otherSignedPreKeyTs
        : int.tryParse(otherSignedPreKeyTs?.toString() ?? '0') ?? 0;
    final otherOneTimePreKey = bundleResponse['one_time_prekey'] != null
        ? Uint8List.fromList(base64Decode(bundleResponse['one_time_prekey'] as String))
        : null;

    try {
      final verifyKey = VerifyKey(otherIdentityKeyPub);
      final timestampBytes = ByteData(8)..setInt64(0, ts);
      final messageToVerify = Uint8List.fromList([
        ...otherSignedPreKeyPub,
        ...timestampBytes.buffer.asUint8List(),
      ]);
      verifyKey.verify(
        signature: Signature(otherSignedPreKeySig),
        message: messageToVerify,
      );
      debugPrint('[SessionManager] Signed prekey verification OK');
    } catch (e) {
      debugPrint('[SessionManager] WARNING: Signed prekey verification failed: $e');
    }

    final ephemeralPrivate = PrivateKey.generate();
    final ephemeralPublic = ephemeralPrivate.publicKey;

    final myIdentityDhPrivate = await _cryptoService.getIdentityDhPrivateKey();
    if (myIdentityDhPrivate == null) {
      throw Exception('Identity DH private key not found');
    }

    final dh1 = _x25519DH(myIdentityDhPrivate, otherSignedPreKeyPub);
    final dh2 = _x25519DH(Uint8List.fromList(ephemeralPrivate.asTypedList), otherIdentityDhPub);
    final dh3 = _x25519DH(Uint8List.fromList(ephemeralPrivate.asTypedList), otherSignedPreKeyPub);

    Uint8List dhConcat;
    if (otherOneTimePreKey != null) {
      final dh4 = _x25519DH(
        Uint8List.fromList(ephemeralPrivate.asTypedList),
        otherOneTimePreKey,
      );
      dhConcat = Uint8List.fromList([...dh1, ...dh2, ...dh3, ...dh4]);
    } else {
      dhConcat = Uint8List.fromList([...dh1, ...dh2, ...dh3]);
    }

    final sharedSecret = _hkdfSha512(
      ikm: dhConcat,
      info: utf8.encode('SCP_X3DH_SharedSecret_v1'),
      length: 32,
      salt: Uint8List(32),
    );

    debugPrint('[SessionManager] X3DH shared secret derived (${sharedSecret.length} bytes)');

    final myIdentityDhPublic = await _cryptoService.getIdentityDhPublicKey();
    if (myIdentityDhPublic == null) {
      throw Exception('Identity DH public key not found');
    }

    final session = _DoubleRatchetSession.initSender(
      sharedSecret: sharedSecret,
      remotePublicKey: otherSignedPreKeyPub,
      ephemeralPublicKey: Uint8List.fromList(ephemeralPublic.asTypedList),
      identityDhPublicKey: myIdentityDhPublic,
    );
    debugPrint('[SessionManager] Double Ratchet initialized as sender');
    return session;
  }

  Future<void> _saveSession(int otherUserId, _DoubleRatchetSession session) async {
    final json = jsonEncode(session.toJson());
    await _secureStorage.write(key: '$_sessionPrefix$otherUserId', value: json);
  }

  Uint8List _x25519DH(Uint8List privateKey, Uint8List publicKey) {
    final shared = Uint8List(32);
    TweetNaCl.crypto_scalarmult(shared, privateKey, publicKey);
    return shared;
  }

  Uint8List _hkdfSha512({
    required Uint8List ikm,
    required List<int> info,
    required int length,
    required Uint8List salt,
  }) {
    final prk = _hmacSha512(salt, ikm);
    final n = (length / 64).ceil();
    var t = Uint8List(0);
    final okm = <int>[];

    for (var i = 1; i <= n; i++) {
      final input = Uint8List.fromList([...t, ...info, i]);
      t = _hmacSha512(prk, input);
      okm.addAll(t);
    }
    return Uint8List.fromList(okm.sublist(0, length));
  }

  Uint8List _hmacSha512(Uint8List key, Uint8List data) {
    const blockSize = 128;
    var keyToUse = key;
    if (keyToUse.length > blockSize) {
      keyToUse = _sha512(keyToUse);
    }
    final paddedKey = Uint8List(blockSize);
    paddedKey.setRange(0, keyToUse.length, keyToUse);
    final ipad = Uint8List(blockSize);
    final opad = Uint8List(blockSize);
    for (var i = 0; i < blockSize; i++) {
      ipad[i] = paddedKey[i] ^ 0x36;
      opad[i] = paddedKey[i] ^ 0x5c;
    }
    final inner = _sha512(Uint8List.fromList([...ipad, ...data]));
    return _sha512(Uint8List.fromList([...opad, ...inner]));
  }

  Uint8List _sha512(Uint8List data) {
    final out = Uint8List(64);
    TweetNaCl.crypto_hash(out, data);
    return out;
  }
}

// ============================================================
// DOUBLE RATCHET SESSION
// ============================================================

class _DoubleRatchetSession {
  Uint8List rootKey;
  Uint8List? sendingChainKey;
  int sendingMessageNumber = 0;
  Uint8List? receivingChainKey;
  int receivingMessageNumber = 0;
  Uint8List dhPrivateKey;
  Uint8List dhPublicKey;
  Uint8List? remoteDhPublicKey;
  Uint8List? ephemeralPublicKey;
  Uint8List? identityDhPublicKey;
  bool isInitialMessage = true;
  final Map<String, Uint8List> _skippedMessageKeys = {};
  static const int maxSkip = 100;

  _DoubleRatchetSession._({
    required this.rootKey,
    required this.dhPrivateKey,
    required this.dhPublicKey,
    this.sendingChainKey,
    this.receivingChainKey,
    this.remoteDhPublicKey,
    this.ephemeralPublicKey,
    this.identityDhPublicKey,
  });

  factory _DoubleRatchetSession.initSender({
    required Uint8List sharedSecret,
    required Uint8List remotePublicKey,
    required Uint8List ephemeralPublicKey,
    required Uint8List identityDhPublicKey,
  }) {
    final newDh = PrivateKey.generate();
    final newDhPrivate = Uint8List.fromList(newDh.asTypedList);
    final newDhPublic = Uint8List.fromList(newDh.publicKey.asTypedList);

    final dhResult = Uint8List(32);
    TweetNaCl.crypto_scalarmult(dhResult, newDhPrivate, remotePublicKey);
    final derived = _kdfRootKey(sharedSecret, dhResult);

    return _DoubleRatchetSession._(
      rootKey: derived['rootKey']!,
      dhPrivateKey: newDhPrivate,
      dhPublicKey: newDhPublic,
      sendingChainKey: derived['chainKey']!,
      remoteDhPublicKey: remotePublicKey,
      ephemeralPublicKey: ephemeralPublicKey,
      identityDhPublicKey: identityDhPublicKey,
    );
  }

  factory _DoubleRatchetSession.initReceiver({
    required Uint8List sharedSecret,
    required Uint8List dhPrivateKey,
    required Uint8List dhPublicKey,
  }) {
    return _DoubleRatchetSession._(
      rootKey: sharedSecret,
      dhPrivateKey: dhPrivateKey,
      dhPublicKey: dhPublicKey,
    );
  }

  void doDhRatchetStep(Uint8List newRemoteDh) {
    remoteDhPublicKey = newRemoteDh;
    final dhResult = Uint8List(32);
    TweetNaCl.crypto_scalarmult(dhResult, dhPrivateKey, newRemoteDh);
    final derived1 = _kdfRootKey(rootKey, dhResult);
    rootKey = derived1['rootKey']!;
    receivingChainKey = derived1['chainKey']!;
    receivingMessageNumber = 0;

    final newDh = PrivateKey.generate();
    dhPrivateKey = Uint8List.fromList(newDh.asTypedList);
    dhPublicKey = Uint8List.fromList(newDh.publicKey.asTypedList);

    final dhResult2 = Uint8List(32);
    TweetNaCl.crypto_scalarmult(dhResult2, dhPrivateKey, newRemoteDh);
    final derived2 = _kdfRootKey(rootKey, dhResult2);
    rootKey = derived2['rootKey']!;
    sendingChainKey = derived2['chainKey']!;
    sendingMessageNumber = 0;
  }

  Map<String, dynamic> encrypt(Uint8List plaintext) {
    final keys = _kdfChainKey(sendingChainKey!);
    sendingChainKey = keys['chainKey']!;
    final messageKey = keys['messageKey']!;
    final msgNum = sendingMessageNumber;
    sendingMessageNumber++;

    final header = _buildHeader(
      dhPublic: dhPublicKey,
      messageNumber: msgNum,
      isInitial: isInitialMessage,
      ephemeralPublicKey: isInitialMessage ? ephemeralPublicKey : null,
      identityDhPublicKey: isInitialMessage ? identityDhPublicKey : null,
    );
    if (isInitialMessage) {
      isInitialMessage = false;
    }

    final box = SecretBox(messageKey);
    final encrypted = box.encrypt(plaintext);
    final ciphertextBytes = Uint8List.fromList([
      ...encrypted.nonce.asTypedList,
      ...encrypted.cipherText.asTypedList,
    ]);

    return {
      'header': header,
      'ciphertext': ciphertextBytes,
      'message_number': msgNum,
    };
  }

  Uint8List decrypt(Uint8List ciphertext, Uint8List header) {
    final parsed = parseHeader(header);
    final remoteDh = Uint8List.fromList(parsed['dhPublic'] as List<int>);
    final msgNum = parsed['messageNumber'] as int;

    if (remoteDhPublicKey == null || !_bytesEqual(remoteDh, remoteDhPublicKey!)) {
      doDhRatchetStep(remoteDh);
    }

    _skipToMessageNumber(msgNum);

    final keys = _kdfChainKey(receivingChainKey!);
    receivingChainKey = keys['chainKey']!;
    final messageKey = keys['messageKey']!;
    receivingMessageNumber++;

    final nonceLen = 24;
    if (ciphertext.length < nonceLen + 1) {
      throw Exception('Ciphertext too short');
    }
    final nonce = ciphertext.sublist(0, nonceLen);
    final cipherOnly = ciphertext.sublist(nonceLen);
    final box = SecretBox(messageKey);
    final decrypted = box.decrypt(
      ByteList(cipherOnly),
      nonce: nonce,
    );
    return Uint8List.fromList(decrypted);
  }

  void _skipToMessageNumber(int target) {
    while (receivingMessageNumber < target) {
      final keys = _kdfChainKey(receivingChainKey!);
      receivingChainKey = keys['chainKey']!;
      final skippedKey = keys['messageKey']!;
      final key = '${base64Encode(remoteDhPublicKey!)}:$receivingMessageNumber';
      _skippedMessageKeys[key] = skippedKey;
      receivingMessageNumber++;
      if (_skippedMessageKeys.length > maxSkip) {
        _skippedMessageKeys.remove(_skippedMessageKeys.keys.first);
      }
    }
  }

  Uint8List _buildHeader({
    required Uint8List dhPublic,
    required int messageNumber,
    bool isInitial = false,
    Uint8List? ephemeralPublicKey,
    Uint8List? identityDhPublicKey,
  }) {
    final flags = isInitial ? 0x01 : 0x00;
    final msgNumBytes = ByteData(4)..setUint32(0, messageNumber);
    final parts = <int>[
      flags,
      ...msgNumBytes.buffer.asUint8List(),
      ...dhPublic,
    ];
    if (isInitial && ephemeralPublicKey != null && identityDhPublicKey != null) {
      parts.addAll(ephemeralPublicKey);
      parts.addAll(identityDhPublicKey);
    }
    return Uint8List.fromList(parts);
  }

  static Map<String, dynamic> parseHeader(Uint8List header) {
    final flags = header[0];
    final isInitial = (flags & 0x01) != 0;
    final msgNum = ByteData.sublistView(header, 1, 5).getUint32(0);
    final dhPublic = header.sublist(5, 37);
    List<int>? ephemeralPublic;
    List<int>? identityDhPublic;
    if (isInitial && header.length >= 101) {
      ephemeralPublic = header.sublist(37, 69);
      identityDhPublic = header.sublist(69, 101);
    }
    return {
      'isInitial': isInitial,
      'messageNumber': msgNum,
      'dhPublic': dhPublic,
      'ephemeralPublic': ephemeralPublic,
      'identityDhPublic': identityDhPublic,
    };
  }

  static Map<String, Uint8List> _kdfRootKey(Uint8List rootKey, Uint8List dhOutput) {
    final info = Uint8List.fromList(utf8.encode('SCP_ROOT_CHAIN_v1'));
    final hmacInput = Uint8List.fromList([...dhOutput, ...info]);
    final output = _hmacSha512Static(rootKey, hmacInput);
    return {
      'rootKey': Uint8List.fromList(output.sublist(0, 32)),
      'chainKey': Uint8List.fromList(output.sublist(32, 64)),
    };
  }

  static Map<String, Uint8List> _kdfChainKey(Uint8List chainKey) {
    final messageKey = _hmacSha512Static(chainKey, Uint8List.fromList([0x01]));
    final newChainKey = _hmacSha512Static(chainKey, Uint8List.fromList([0x02]));
    return {
      'messageKey': Uint8List.fromList(messageKey.sublist(0, 32)),
      'chainKey': Uint8List.fromList(newChainKey.sublist(0, 32)),
    };
  }

  static Uint8List _hmacSha512Static(Uint8List key, Uint8List data) {
    const blockSize = 128;
    var keyToUse = key;
    if (keyToUse.length > blockSize) {
      final out = Uint8List(64);
      TweetNaCl.crypto_hash(out, keyToUse);
      keyToUse = out;
    }
    final paddedKey = Uint8List(blockSize);
    paddedKey.setRange(0, keyToUse.length, keyToUse);
    final ipad = Uint8List(blockSize);
    final opad = Uint8List(blockSize);
    for (var i = 0; i < blockSize; i++) {
      ipad[i] = paddedKey[i] ^ 0x36;
      opad[i] = paddedKey[i] ^ 0x5c;
    }
    final innerInput = Uint8List.fromList([...ipad, ...data]);
    final innerHash = Uint8List(64);
    TweetNaCl.crypto_hash(innerHash, innerInput);
    final outerInput = Uint8List.fromList([...opad, ...innerHash]);
    final outerHash = Uint8List(64);
    TweetNaCl.crypto_hash(outerHash, outerInput);
    return outerHash;
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
        'rootKey': base64Encode(rootKey),
        'sendingChainKey': sendingChainKey != null ? base64Encode(sendingChainKey!) : null,
        'sendingMessageNumber': sendingMessageNumber,
        'receivingChainKey': receivingChainKey != null ? base64Encode(receivingChainKey!) : null,
        'receivingMessageNumber': receivingMessageNumber,
        'dhPrivateKey': base64Encode(dhPrivateKey),
        'dhPublicKey': base64Encode(dhPublicKey),
        'remoteDhPublicKey': remoteDhPublicKey != null ? base64Encode(remoteDhPublicKey!) : null,
        'ephemeralPublicKey': ephemeralPublicKey != null ? base64Encode(ephemeralPublicKey!) : null,
        'identityDhPublicKey': identityDhPublicKey != null ? base64Encode(identityDhPublicKey!) : null,
        'isInitialMessage': isInitialMessage,
      };

  factory _DoubleRatchetSession.fromJson(Map<String, dynamic> json) {
    final session = _DoubleRatchetSession._(
      rootKey: Uint8List.fromList(base64Decode(json['rootKey'] as String)),
      dhPrivateKey: Uint8List.fromList(base64Decode(json['dhPrivateKey'] as String)),
      dhPublicKey: Uint8List.fromList(base64Decode(json['dhPublicKey'] as String)),
      sendingChainKey: json['sendingChainKey'] != null
          ? Uint8List.fromList(base64Decode(json['sendingChainKey'] as String))
          : null,
      receivingChainKey: json['receivingChainKey'] != null
          ? Uint8List.fromList(base64Decode(json['receivingChainKey'] as String))
          : null,
      remoteDhPublicKey: json['remoteDhPublicKey'] != null
          ? Uint8List.fromList(base64Decode(json['remoteDhPublicKey'] as String))
          : null,
      ephemeralPublicKey: json['ephemeralPublicKey'] != null
          ? Uint8List.fromList(base64Decode(json['ephemeralPublicKey'] as String))
          : null,
      identityDhPublicKey: json['identityDhPublicKey'] != null
          ? Uint8List.fromList(base64Decode(json['identityDhPublicKey'] as String))
          : null,
    );
    session.sendingMessageNumber = json['sendingMessageNumber'] as int? ?? 0;
    session.receivingMessageNumber = json['receivingMessageNumber'] as int? ?? 0;
    session.isInitialMessage = json['isInitialMessage'] as bool? ?? false;
    return session;
  }
}
