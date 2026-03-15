import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pinenacl/ed25519.dart';
import 'package:pinenacl/tweetnacl.dart';
import 'package:pinenacl/x25519.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'crypto_service.dart';

/// Manages E2E encryption sessions between users.
/// Each pair of users has one session (identified by the other user's ID).
/// Singleton so that deleteSession (e.g. on session reset) clears the same in-memory
/// state used by ChatDetailScreen for encrypt/decrypt.
class SessionManager {
  static SessionManager? _instance;

  static const String _sessionPrefix = 'scp_session_';
  static const String _sessionPrevPrefix = 'scp_session_prev_';
  static const String _cachePrefix = 'scp_msg_cache_';
  static const String _failedPrefix = 'e2e_failed_';
  static const String _e2eInstallIdKey = 'e2e_install_id';

  /// No automatic wipe or key regeneration. Keys persist in Keychain across reinstall/update.
  /// Only updates install id for logging; never clears sessions or keys.
  static Future<void> autoResetIfNewInstall(ApiService apiService) async {
    final prefs = await SharedPreferences.getInstance();
    String currentBuildNumber;
    try {
      final info = await PackageInfo.fromPlatform();
      currentBuildNumber = info.buildNumber;
    } catch (_) {
      currentBuildNumber = '0';
    }
    final storedInstallId = prefs.getString(_e2eInstallIdKey);
    if (storedInstallId != currentBuildNumber) {
      await prefs.setString(_e2eInstallIdKey, currentBuildNumber);
      debugPrint('[SessionManager] Install id updated (no wipe, keys preserved in Keychain)');
    } else {
      debugPrint('[SessionManager] E2E sessions OK, same install');
    }
  }

  final FlutterSecureStorage _secureStorage;
  final ApiService _apiService;
  final CryptoService _cryptoService;

  final Map<int, _DoubleRatchetSession> _sessions = {};
  final Map<int, int> _knownKeyVersions = {};

  /// Call early at app startup to validate session storage; never throws.
  Future<void> warmupSessionStorage() async {
    debugPrint('[SessionManager] startup session load begin');
    try {
      await _secureStorage.readAll();
      debugPrint('[SessionManager] startup session load completed');
    } catch (e) {
      debugPrint('[SessionManager] startup session load failed: $e');
    }
  }

  /// Cache of plaintext for messages we sent (messageId → plaintext).
  final Map<String, String> _sentMessagePlaintexts = {};
  final Map<String, bool> _failedDecryptCache = {};
  /// Log Cache MISS only once per messageId to avoid console flooding.
  final Set<String> _loggedCacheMisses = {};

  factory SessionManager({
    ApiService? apiService,
    CryptoService? cryptoService,
    FlutterSecureStorage? secureStorage,
  }) {
    _instance ??= SessionManager._internal(
      apiService: apiService ?? ApiService(),
      cryptoService: cryptoService ?? CryptoService(apiService: apiService ?? ApiService()),
      secureStorage: secureStorage,
    );
    return _instance!;
  }

  SessionManager._internal({
    required ApiService apiService,
    required CryptoService cryptoService,
    FlutterSecureStorage? secureStorage,
  })  : _apiService = apiService,
        _cryptoService = cryptoService,
        _secureStorage = secureStorage ??
            FlutterSecureStorage(
              aOptions: const AndroidOptions(encryptedSharedPreferences: true),
              iOptions: const IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
                accountName: 'com.axphone.app.e2e',
                groupId: 'F28CW3467A.com.axphone.app.e2e',
              ),
            );

  /// Ensure we have an active session with the given user (for sending).
  /// If no session exists, performs X3DH handshake. If existing session's remote bundle changed, drops it and does fresh X3DH.
  Future<_DoubleRatchetSession> _getOrCreateSession(int otherUserId) async {
    _DoubleRatchetSession? session;
    if (_sessions.containsKey(otherUserId)) {
      session = _sessions[otherUserId]!;
    } else {
      try {
        debugPrint('[SessionManager] session load begin for user $otherUserId');
        final stored = await _secureStorage.read(key: '$_sessionPrefix$otherUserId');
        if (stored != null) {
          session = _DoubleRatchetSession.fromJson(jsonDecode(stored) as Map<String, dynamic>);
          _sessions[otherUserId] = session;
          debugPrint('[SessionManager] Loaded existing session for user $otherUserId');
        }
      } catch (e) {
        debugPrint('[SessionManager] session load failed for user $otherUserId: $e');
      }
    }

    if (session != null) {
      final stillValid = await _ensureSessionMatchesRemoteBundle(otherUserId, session);
      if (stillValid != null) {
        return stillValid;
      }
      session = null;
    }

    debugPrint('[E2E-Send] forcing fresh X3DH bootstrap for peer $otherUserId');
    final newSession = await _performX3DHAndInitSession(otherUserId);
    await clearRehandshakeFlag(otherUserId);
    await _remoteLog('[GetOrCreate] newSession created for peer=$otherUserId '
        'remoteDhPub=${base64Encode(newSession.remoteDhPublicKey ?? Uint8List(0))} '
        'remoteIdDhPub=${base64Encode(newSession.remoteIdentityDhPublicKey ?? Uint8List(0))}');
    _sessions[otherUserId] = newSession;
    final currentStored = await _secureStorage.read(key: '$_sessionPrefix$otherUserId');
    if (currentStored != null && currentStored.isNotEmpty) {
      await _secureStorage.write(key: '$_sessionPrevPrefix$otherUserId', value: currentStored);
      debugPrint('[SessionAudit] action=backup_current senderId=$otherUserId reason=before_overwrite_after_remote_bundle_change');
    }
    await _saveSession(otherUserId, newSession);
    newSession.remoteKeyVersion = _knownKeyVersions[otherUserId];
    await _saveSession(otherUserId, newSession);
    debugPrint('[SessionAudit] action=overwrite senderId=$otherUserId reason=new_session_created_after_remote_bundle_change');
    final newFp = _DoubleRatchetSession.fingerprint(newSession.remoteIdentityDhPublicKey, newSession.remoteSignedPreKeyPublic ?? newSession.remoteDhPublicKey);
    debugPrint('[E2E-Send] new session saved with fingerprint=$newFp');
    debugPrint('[E2E-Send] fresh bootstrap completed for peer $otherUserId');
    debugPrint('[E2E-Flow] peer session recovered after remote bundle change for peer $otherUserId');
    return newSession;
  }

  /// If session has stored remote fingerprint, fetch current bundle and compare. If bundle changed, drop session and return null.
  /// Uses remoteSignedPreKeyPublic (stable) for prekey comparison, not remoteDhPublicKey (updated at each ratchet step).
  Future<_DoubleRatchetSession?> _ensureSessionMatchesRemoteBundle(int otherUserId, _DoubleRatchetSession session) async {
    final storedPrekey = session.remoteSignedPreKeyPublic ?? session.remoteDhPublicKey;
    if (session.remoteIdentityDhPublicKey == null || storedPrekey == null) {
      return session;
    }
    try {
      final bundleResponse = await _apiService.get('/encryption/keys/$otherUserId/');

      // Controlla key_version prima del confronto binario (più veloce)
      final remoteKeyVersion = bundleResponse['key_version'] as int?;
      if (remoteKeyVersion != null) {
        final knownVersion = _knownKeyVersions[otherUserId];
        // Cortocircuita SOLO se la versione è nota E la sessione ha già le chiavi aggiornate (doppio controllo)
        if (knownVersion != null &&
            knownVersion == remoteKeyVersion &&
            session.remoteKeyVersion == remoteKeyVersion) {
          return session;
        }
        _knownKeyVersions[otherUserId] = remoteKeyVersion;
      }

      final currentIdentityDh = Uint8List.fromList(base64Decode(
        (bundleResponse['identity_dh_key'] ?? bundleResponse['identity_dh_key_public']) as String,
      ));
      final currentSignedPrekey = Uint8List.fromList(base64Decode(
        (bundleResponse['signed_prekey'] ?? bundleResponse['signed_prekey_public']) as String,
      ));
      final peerFp = _DoubleRatchetSession.fingerprint(currentIdentityDh, currentSignedPrekey);
      final storedFp = _DoubleRatchetSession.fingerprint(session.remoteIdentityDhPublicKey, storedPrekey);
      debugPrint('[E2E-Send] peer bundle fingerprint=$peerFp');
      debugPrint('[E2E-Send] stored session fingerprint=$storedFp');
      final identityMatch = session.remoteIdentityDhPublicKey!.length == currentIdentityDh.length &&
          _bytesEqualStatic(session.remoteIdentityDhPublicKey!, currentIdentityDh);
      final prekeyMatch = storedPrekey.length == currentSignedPrekey.length &&
          _bytesEqualStatic(storedPrekey, currentSignedPrekey);
      if (identityMatch && prekeyMatch) {
        return session;
      }
      debugPrint('[SessionAudit] action=send_path_stale_session_detected senderId=$otherUserId reason=remote_bundle_changed');
      debugPrint('[SessionAudit] action=skip_delete senderId=$otherUserId reason=preserve_historical_session_until_replaced');
      return null;
    } catch (e) {
      debugPrint('[E2E-Send] remote bundle check skipped for peer $otherUserId because fetch failed');
      return session;
    }
  }

  static bool _bytesEqualStatic(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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

  /// Clear all persisted failed-decrypt marks (e.g. after login when sessions are cleared).
  Future<void> clearAllFailedDecryptMarks() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_failedPrefix)).toList();
    for (final k in keys) {
      await prefs.remove(k);
    }
    _failedDecryptCache.clear();
    print('[SessionManager] Cleared ${keys.length} failed decrypt marks');
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
    try {
      print('[CryptoDebug] encryptMessage for userId=$otherUserId needsRehandshake=${await needsRehandshake(otherUserId)}');
      debugPrint('[SessionManager] encrypt called, instance hashCode: ${hashCode}');
      if (await needsRehandshake(otherUserId)) {
        await deleteSession(otherUserId, reason: 'rehandshake_before_encrypt');
        await clearRehandshakeFlag(otherUserId);
      }
      final session = await _getOrCreateSession(otherUserId);
      await _remoteLog('[Encrypt] session for peer=$otherUserId '
          'remoteDhPub=${base64Encode(session.remoteDhPublicKey ?? Uint8List(0))}');
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
    } catch (e, st) {
      await _remoteLog(
        '[EncryptCrash] userId=$otherUserId error=${e.toString()} stack=${st.toString().substring(0, 300)}',
      );
      rethrow;
    }
  }

  /// Decrypt a received message from a specific user.
  /// [combinedPayload] is the full wire format: [2B headerLen][header][nonce+ciphertext].
  /// [messageId] optional: if provided and decrypt fails, message is marked as irrecuperable (no session rollback).
  Future<String> decryptMessage(
    int senderUserId,
    Uint8List combinedPayload, {
    String? messageId,
  }) async {
    print('[CryptoDebug] decryptMessage from userId=$senderUserId');
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
    final isInitialMessage = headerLen >= 100 || isInitial;

    _DoubleRatchetSession session;

    // Un messaggio iniziale (X3DH) sovrascrive sempre la sessione esistente (session reset).
    if (isInitialMessage) {
      debugPrint('[ChatDecrypt] sessionLookup=initial_message_creates_session (senderId=$senderUserId messageId=$messageId)');
      debugPrint('[E2E-Recv] initial message detected from peer $senderUserId');
      debugPrint('[SessionManager] Creating receiver session from initial message (overwriting if any)');
      session = await _createReceiverSession(senderUserId, parsedHeader);
      _sessions[senderUserId] = session;
    } else if (_sessions.containsKey(senderUserId)) {
      session = _sessions[senderUserId]!;
      debugPrint('[ChatDecrypt] sessionLookup=success_in_memory (senderId=$senderUserId messageId=$messageId)');
      debugPrint('[SessionManager] Using existing session for user $senderUserId');
      // Check if sender's bundle changed (e.g. after reinstall) — if so, invalidate session
      final stillValid = await _ensureSessionMatchesRemoteBundle(senderUserId, session);
      if (stillValid == null) {
        _sessions.remove(senderUserId);
        await _secureStorage.delete(key: '$_sessionPrefix$senderUserId');
        if (isInitialMessage) {
          debugPrint('[ChatDecrypt] sender bundle changed — retrying as initial for $senderUserId');
          await _remoteLog('[DecryptRX] senderBundleChanged userId=$senderUserId — retrying as initial');
          try {
            session = await _createReceiverSession(senderUserId, parsedHeader);
            _sessions[senderUserId] = session;
          } catch (e) {
            await _remoteLog('[DecryptRX] senderBundleChanged retry failed userId=$senderUserId error=$e');
            throw Exception('Sender bundle changed — session invalidated, retry failed: $e');
          }
        } else {
          // Bundle cambiato su messaggio non-initial:
          // 1. Drop sessione locale (così il mittente farà nuovo X3DH al prossimo invio)
          // 2. Cancella il flag failed-decrypt per questo messaggio così verrà ritentato dopo re-handshake
          await _remoteLog('[DecryptRX] senderBundleChanged userId=$senderUserId — non-initial, dropping session and forcing re-handshake');
          _sessions.remove(senderUserId);
          await _secureStorage.delete(key: '$_sessionPrefix$senderUserId');
          await _secureStorage.delete(key: '$_sessionPrevPrefix$senderUserId');
          if (messageId != null) {
            _failedDecryptCache.remove(messageId);
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove('$_failedPrefix$messageId');
          }
          throw Exception('Sender bundle changed — session cleared, waiting for re-handshake');
        }
      }
    } else {
      try {
        debugPrint('[SessionManager] session load begin for user $senderUserId');
        final stored = await _secureStorage.read(key: '$_sessionPrefix$senderUserId');
        if (stored != null) {
          session = _DoubleRatchetSession.fromJson(jsonDecode(stored) as Map<String, dynamic>);
          _sessions[senderUserId] = session;
          debugPrint('[ChatDecrypt] sessionLookup=success_from_storage (senderId=$senderUserId messageId=$messageId)');
          debugPrint('[SessionManager] Loaded session from storage for user $senderUserId');
        } else {
          final backupStored = await _secureStorage.read(key: '$_sessionPrevPrefix$senderUserId');
          if (backupStored != null) {
            session = _DoubleRatchetSession.fromJson(jsonDecode(backupStored) as Map<String, dynamic>);
            _sessions[senderUserId] = session;
            debugPrint('[SessionAudit] action=load_backup senderId=$senderUserId source=storage');
            debugPrint('[SessionManager] Loaded backup session from storage for user $senderUserId');
          } else if (isInitial) {
            debugPrint('[ChatDecrypt] sessionLookup=initial_creates_session (senderId=$senderUserId messageId=$messageId)');
            debugPrint('[SessionManager] Creating receiver session from initial message');
            session = await _createReceiverSession(senderUserId, parsedHeader);
            _sessions[senderUserId] = session;
          } else {
            debugPrint('[ChatDecrypt] sessionLookup=missing (senderId=$senderUserId messageId=$messageId) — No session exists and message is not initial');
            // Auto-clear broken session so next message triggers new X3DH
            try {
              await deleteSession(senderUserId, reason: 'decrypt_fail_auto_heal');
              await _secureStorage.write(
                key: 'scp_needs_rehandshake_$senderUserId',
                value: 'true',
              );
            } catch (_) {}
            throw Exception('No session exists and message is not initial — cannot decrypt');
          }
        }
      } catch (e) {
        debugPrint('[SessionManager] session load failed for user $senderUserId: $e');
        if (!isInitial) rethrow;
        debugPrint('[ChatDecrypt] sessionLookup=recovered_after_error (senderId=$senderUserId messageId=$messageId)');
        session = await _createReceiverSession(senderUserId, parsedHeader);
        _sessions[senderUserId] = session;
      }
    }

    try {
      final plaintext = session.decrypt(encryptedPayload, header);
      await _saveSession(senderUserId, session);
      final result = utf8.decode(plaintext);
      debugPrint(
        '[SessionManager] Decrypted message from user $senderUserId: "${result.substring(0, result.length.clamp(0, 20))}..."',
      );
      return result;
    } catch (e) {
      print('[CryptoDebug] decryptMessage FAILED: $e');
      print('[DecryptError] messageId=$messageId '
          'sender=$senderUserId '
          'payloadLen=${combinedPayload.length} '
          'error=$e '
          'stack=${StackTrace.current}');
      debugPrint('[SessionManager] Decrypt failed for $messageId: $e');
      debugPrint('[E2E-Recv] decrypt failed, no retry to avoid OTP double-consume');
      final backupStored = await _secureStorage.read(key: '$_sessionPrevPrefix$senderUserId');
      if (backupStored != null) {
        try {
          final backupSession = _DoubleRatchetSession.fromJson(jsonDecode(backupStored) as Map<String, dynamic>);
          final plaintext = backupSession.decrypt(encryptedPayload, header);
          final result = utf8.decode(plaintext);
          debugPrint('[SessionAudit] action=decrypt_with_backup senderId=$senderUserId messageId=$messageId');
          return result;
        } catch (_) {}
      }
      if (messageId != null) {
        debugPrint('[E2E] message $messageId marked undecryptable (placeholder will be shown)');
        await markDecryptFailed(messageId);
      }
      // Auto-clear broken session so next message triggers new X3DH
      try {
        await deleteSession(senderUserId, reason: 'decrypt_fail_auto_heal');
        await _secureStorage.write(
          key: 'scp_needs_rehandshake_$senderUserId',
          value: 'true',
        );
      } catch (_) {}
      // Auto-recovery: controlla se le chiavi del mittente sono cambiate
      try {
        final versionResponse = await _apiService.get(
          '/encryption/keys/$senderUserId/version/',
        );
        final remoteKeyVersion = versionResponse['key_version'] as int?;
        final knownVersion = _knownKeyVersions[senderUserId];
        if (remoteKeyVersion != null && remoteKeyVersion != knownVersion) {
          debugPrint('[E2E] Auto-recovery: key_version cambiata per user $senderUserId '
              '(known=$knownVersion remote=$remoteKeyVersion) — reset sessione');
          _knownKeyVersions[senderUserId] = remoteKeyVersion;
          await deleteSession(senderUserId, reason: 'auto_recovery_key_version_changed');
          await _secureStorage.write(
            key: 'scp_needs_rehandshake_$senderUserId',
            value: 'true',
          );
          debugPrint('[E2E] Auto-recovery completato: nuova sessione verrà creata '
              'al prossimo messaggio iniziale da user $senderUserId');
        }
      } catch (versionCheckError) {
        debugPrint('[E2E] Auto-recovery version check fallito: $versionCheckError');
      }
      rethrow;
    }
  }

  /// Whether the session with [otherUserId] was marked for rehandshake after a decrypt failure.
  Future<bool> needsRehandshake(int otherUserId) async {
    return await _secureStorage.read(
      key: 'scp_needs_rehandshake_$otherUserId',
    ) == 'true';
  }

  /// Clear the rehandshake flag for [otherUserId] after a new X3DH handshake.
  Future<void> clearRehandshakeFlag(int otherUserId) async {
    await _secureStorage.delete(
      key: 'scp_needs_rehandshake_$otherUserId',
    );
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

      final int? otpKeyId = parsedHeader['otpKeyId'] as int?;
      Uint8List dhConcat;
      Uint8List? myOtpPrivate;
      if (otpKeyId != null) {
        myOtpPrivate = await _cryptoService.getOneTimePreKeyPrivate(otpKeyId);
        await _remoteLog('[X3DH-RX-OTP2] otpKeyId=$otpKeyId '
            'found=${myOtpPrivate != null}');
      }
      await _remoteLog('[X3DH-RX-OTP] otpKeyId=$otpKeyId '
          'myOtpPrivate=${myOtpPrivate != null}');
      if (myOtpPrivate != null) {
        final dh4 = _x25519DH(myOtpPrivate, senderEphemeralPub);
        dhConcat = Uint8List.fromList([...dh1, ...dh2, ...dh3, ...dh4]);
        debugPrint('[SessionManager] Receiver X3DH: 4 DH operations (with OTP)');
      } else {
        dhConcat = Uint8List.fromList([...dh1, ...dh2, ...dh3]);
        debugPrint('[SessionManager] Receiver X3DH: 3 DH operations (no OTP)');
      }

      await _remoteLog('[X3DH-RX-HKDF] dhConcat_len=${dhConcat.length} '
          'dhConcat_first8=${base64Encode(dhConcat.sublist(0, 8))} '
          'dhConcat_last8=${base64Encode(dhConcat.sublist(dhConcat.length - 8))} '
          'hasOtp=${myOtpPrivate != null}');
      final sharedSecret = _hkdfSha512(
        ikm: dhConcat,
        info: utf8.encode('SCP_X3DH_SharedSecret_v1'),
        length: 32,
        salt: Uint8List(32),
      );
      await _remoteLog('[X3DH-RX] ss=${base64Encode(sharedSecret.sublist(0, 8))} '
          'dh1=${base64Encode(dh1.sublist(0, 8))} '
          'dh2=${base64Encode(dh2.sublist(0, 8))} '
          'dh3=${base64Encode(dh3.sublist(0, 8))} '
          'mySpkPub=${base64Encode(mySignedPreKeyPublic.sublist(0, 8))} '
          'senderIdDhPub=${base64Encode(senderIdentityDhPub.sublist(0, 8))} '
          'senderEphPub=${base64Encode(senderEphemeralPub.sublist(0, 8))}');
      debugPrint('[X3DH-RX] Shared secret derived: ${sharedSecret.length} bytes');
      debugPrint('[SessionManager] Receiver X3DH shared secret derived (${sharedSecret.length} bytes)');

      final session = _DoubleRatchetSession.initReceiver(
        sharedSecret: sharedSecret,
        dhPrivateKey: mySignedPreKeyPrivate,
        dhPublicKey: mySignedPreKeyPublic,
        remoteSignedPreKeyPublic: Uint8List.fromList(senderDhPublic),
      );
      session.doDhRatchetStep(senderDhPublic);
      await _saveSession(senderUserId, session);
      if (otpKeyId != null) {
        await _cryptoService.deleteOneTimePreKey(otpKeyId);
      }
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

  /// Clears the cached E2E session for one user (e.g. when creating a new private chat).
  /// Removes from in-memory cache and Keychain so the next message will trigger a fresh X3DH handshake.
  Future<void> clearSessionForUser(int userId) async {
    await deleteSession(userId, reason: 'new_private_chat');
  }

  /// Chiamato quando il notify server segnala che un utente ha cambiato le chiavi.
  /// Resetta la sessione con quell'utente in modo silenzioso.
  Future<void> handleKeysChanged(int userId, int newKeyVersion) async {
    final known = _knownKeyVersions[userId];
    if (known != null && known == newKeyVersion) {
      debugPrint('[E2E] keys_changed ignorato: version=$newKeyVersion già nota per user $userId');
      return;
    }
    debugPrint('[E2E] keys_changed: user=$userId newVersion=$newKeyVersion — reset sessione');
    _knownKeyVersions[userId] = newKeyVersion;
    await deleteSession(userId, reason: 'keys_changed_event');
  }

  /// Remove the E2E session for one user (e.g. after chat re-open from hidden).
  /// Clears both active and backup session for that peer.
  /// [reason] used for [SessionAudit] logging.
  Future<void> deleteSession(int otherUserId, {String reason = 'unspecified'}) async {
    debugPrint('[SessionAudit] action=delete senderId=$otherUserId reason=$reason');
    _sessions.remove(otherUserId);
    await _secureStorage.delete(key: '$_sessionPrefix$otherUserId');
    final hadBackup = await _secureStorage.read(key: '$_sessionPrevPrefix$otherUserId');
    if (hadBackup != null) {
      debugPrint('[SessionAudit] action=delete_backup senderId=$otherUserId reason=$reason');
    }
    await _secureStorage.delete(key: '$_sessionPrevPrefix$otherUserId');
    debugPrint('[SessionManager] Session deleted for user $otherUserId');
  }

  Future<void> clearAllSessions() async {
    _sessions.clear();
    _sentMessagePlaintexts.clear();
    final all = await _secureStorage.readAll();
    for (final key in all.keys) {
      if (key.startsWith(_sessionPrefix) || key.startsWith(_sessionPrevPrefix)) {
        await _secureStorage.delete(key: key);
      }
    }
    debugPrint('[SessionManager] All sessions cleared');
  }

  Future<void> _remoteLog(String message) async {
    try {
      await _apiService.post('/encryption/debug/log/',
          body: {'message': message}, requiresAuth: true);
    } catch (e1) {
      try {
        await _apiService.post('/encryption/debug/log/',
            body: {'message': message}, requiresAuth: false);
      } catch (_) {}
    }
  }

  /// Public API for callers (e.g. chat UI) to send debug logs to the server.
  Future<void> remoteLog(String message) async => _remoteLog(message);

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
    final otpKeyIdRaw = bundleResponse['one_time_prekey_id'];
    final int? otpKeyId = otpKeyIdRaw is int
        ? otpKeyIdRaw
        : (otpKeyIdRaw != null ? int.tryParse(otpKeyIdRaw.toString()) : null);
    if (otherOneTimePreKey != null) {
      await _remoteLog('[X3DH-TX-OTP] otpKeyId=$otpKeyId '
          'otherOtpPub=${base64Encode(otherOneTimePreKey)}');
    }

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

    await _remoteLog('[X3DH-TX-HKDF] dhConcat_len=${dhConcat.length} '
        'dhConcat_first8=${base64Encode(dhConcat.sublist(0, 8))} '
        'dhConcat_last8=${base64Encode(dhConcat.sublist(dhConcat.length - 8))} '
        'hasOtp=${otherOneTimePreKey != null}');
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
    await _remoteLog('[X3DH-TX] ss=${base64Encode(sharedSecret.sublist(0, 8))} '
        'dh1=${base64Encode(dh1.sublist(0, 8))} '
        'dh2=${base64Encode(dh2.sublist(0, 8))} '
        'dh3=${base64Encode(dh3.sublist(0, 8))} '
        'myIdDhPub=${base64Encode(myIdentityDhPublic.sublist(0, 8))} '
        'otherSpkPub=${base64Encode(otherSignedPreKeyPub.sublist(0, 8))} '
        'ephPub=${base64Encode(Uint8List.fromList(ephemeralPublic.asTypedList).sublist(0, 8))}');

    final session = _DoubleRatchetSession.initSender(
      sharedSecret: sharedSecret,
      remotePublicKey: otherSignedPreKeyPub,
      remoteIdentityDhPublicKey: otherIdentityDhPub,
      ephemeralPublicKey: Uint8List.fromList(ephemeralPublic.asTypedList),
      identityDhPublicKey: myIdentityDhPublic,
      otpKeyId: otpKeyId,
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
  /// Peer's identity DH public (from bundle when we are sender). Used to detect remote bundle change.
  Uint8List? remoteIdentityDhPublicKey;
  /// Peer's signed prekey from bundle; set only in initSender/initReceiver, never updated by ratchet. Used for bundle-change check.
  Uint8List? remoteSignedPreKeyPublic;
  /// Remote key_version when session was created/validated; used for short-circuit in _ensureSessionMatchesRemoteBundle.
  int? remoteKeyVersion;
  int? _otpKeyId;
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
    this.remoteIdentityDhPublicKey,
    this.remoteSignedPreKeyPublic,
    int? otpKeyId,
  }) : _otpKeyId = otpKeyId;

  /// Short fingerprint for logging (identity_dh + signed_prekey first bytes).
  static String fingerprint(Uint8List? identityDh, Uint8List? signedPrekey) {
    if (identityDh == null && signedPrekey == null) return 'none';
    final a = identityDh != null ? base64Encode(identityDh.sublist(0, identityDh.length.clamp(0, 8))) : '';
    final b = signedPrekey != null ? base64Encode(signedPrekey.sublist(0, signedPrekey.length.clamp(0, 8))) : '';
    return '$a|$b';
  }

  factory _DoubleRatchetSession.initSender({
    required Uint8List sharedSecret,
    required Uint8List remotePublicKey,
    required Uint8List remoteIdentityDhPublicKey,
    required Uint8List ephemeralPublicKey,
    required Uint8List identityDhPublicKey,
    int? otpKeyId,
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
      remoteIdentityDhPublicKey: remoteIdentityDhPublicKey,
      remoteSignedPreKeyPublic: remotePublicKey,
      ephemeralPublicKey: ephemeralPublicKey,
      identityDhPublicKey: identityDhPublicKey,
      otpKeyId: otpKeyId,
    );
  }

  factory _DoubleRatchetSession.initReceiver({
    required Uint8List sharedSecret,
    required Uint8List dhPrivateKey,
    required Uint8List dhPublicKey,
    Uint8List? remoteSignedPreKeyPublic,
  }) {
    return _DoubleRatchetSession._(
      rootKey: sharedSecret,
      dhPrivateKey: dhPrivateKey,
      dhPublicKey: dhPublicKey,
      remoteSignedPreKeyPublic: remoteSignedPreKeyPublic,
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
      otpKeyId: isInitialMessage ? _otpKeyId : null,
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
    int? otpKeyId,
  }) {
    final flags = (isInitial && ephemeralPublicKey != null) ? 0x01 : 0x00;
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
    if (isInitial && otpKeyId != null) {
      final otpIdBytes = ByteData(4)..setUint32(0, otpKeyId, Endian.big);
      parts.addAll(otpIdBytes.buffer.asUint8List());
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
    int? otpKeyId;
    if (isInitial && header.length >= 101) {
      ephemeralPublic = header.sublist(37, 69);
      identityDhPublic = header.sublist(69, 101);
    }
    if (isInitial && header.length >= 105) {
      otpKeyId = ByteData.sublistView(header, 101, 105).getUint32(0, Endian.big);
    }
    return {
      'isInitial': isInitial,
      'messageNumber': msgNum,
      'dhPublic': dhPublic,
      'ephemeralPublic': ephemeralPublic,
      'identityDhPublic': identityDhPublic,
      'otpKeyId': otpKeyId,
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
        'remoteIdentityDhPublicKey': remoteIdentityDhPublicKey != null ? base64Encode(remoteIdentityDhPublicKey!) : null,
        'remoteSignedPreKeyPublic': remoteSignedPreKeyPublic != null ? base64Encode(remoteSignedPreKeyPublic!) : null,
        'ephemeralPublicKey': ephemeralPublicKey != null ? base64Encode(ephemeralPublicKey!) : null,
        'identityDhPublicKey': identityDhPublicKey != null ? base64Encode(identityDhPublicKey!) : null,
        'isInitialMessage': isInitialMessage,
        'remoteKeyVersion': remoteKeyVersion,
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
      remoteIdentityDhPublicKey: json['remoteIdentityDhPublicKey'] != null
          ? Uint8List.fromList(base64Decode(json['remoteIdentityDhPublicKey'] as String))
          : null,
      remoteSignedPreKeyPublic: json['remoteSignedPreKeyPublic'] != null
          ? Uint8List.fromList(base64Decode(json['remoteSignedPreKeyPublic'] as String))
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
    session.remoteKeyVersion = json['remoteKeyVersion'] as int?;
    return session;
  }
}
