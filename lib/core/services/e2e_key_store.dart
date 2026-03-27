import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Servizio centralizzato per la persistenza sicura delle chiavi E2E.
/// Salva le chiavi in iOS Keychain / Android Keystore.
/// Le chiavi sono associate all'userId per isolamento multi-utente.
class E2EKeyStore {
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      accountName: 'com.axphone.app.e2e_keys',
    ),
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _indexKey = 'e2e_key_index';

  // Attachment keys
  static String _attKey(int userId, String attId) => 'e2e_att_key_${userId}_$attId';
  static String _captionKey(int userId, String attId) => 'e2e_att_cap_${userId}_$attId';

  static Future<void> saveAttachmentKey(int userId, String attId, String keyB64, String caption) async {
    await _storage.write(key: _attKey(userId, attId), value: keyB64);
    if (caption.isNotEmpty) await _storage.write(key: _captionKey(userId, attId), value: caption);
    await _addToIndex(userId, 'att:$attId');
  }

  static Future<String?> getAttachmentKey(int userId, String attId) async {
    return await _storage.read(key: _attKey(userId, attId));
  }

  static Future<String?> getAttachmentCaption(int userId, String attId) async {
    return await _storage.read(key: _captionKey(userId, attId));
  }

  // Message plaintext cache
  static String _msgKey(int userId, String msgId) => 'e2e_msg_${userId}_$msgId';

  static Future<void> saveMessagePlaintext(int userId, String msgId, String plaintext) async {
    await _storage.write(key: _msgKey(userId, msgId), value: plaintext);
    await _addToIndex(userId, 'msg:$msgId');
  }

  static Future<String?> getMessagePlaintext(int userId, String msgId) async {
    return await _storage.read(key: _msgKey(userId, msgId));
  }

  // Index per pulizia per userId
  static Future<void> _addToIndex(int userId, String entry) async {
    final indexKey = '${_indexKey}_$userId';
    final raw = await _storage.read(key: indexKey);
    final list = raw != null ? (jsonDecode(raw) as List).cast<String>() : <String>[];
    if (!list.contains(entry)) {
      list.add(entry);
      await _storage.write(key: indexKey, value: jsonEncode(list));
    }
  }

  /// Elimina tutte le chiavi di un utente (es. al logout definitivo).
  static Future<void> clearForUser(int userId) async {
    final indexKey = '${_indexKey}_$userId';
    final raw = await _storage.read(key: indexKey);
    if (raw != null) {
      final list = (jsonDecode(raw) as List).cast<String>();
      for (final entry in list) {
        final parts = entry.split(':');
        if (parts.length < 2) continue;
        final type = parts[0];
        final id = parts.sublist(1).join(':');
        if (type == 'att') {
          await _storage.delete(key: _attKey(userId, id));
          await _storage.delete(key: _captionKey(userId, id));
        } else if (type == 'msg') {
          await _storage.delete(key: _msgKey(userId, id));
        }
      }
      await _storage.delete(key: indexKey);
    }
  }
}
