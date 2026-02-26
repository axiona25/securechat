// SecureChat — Client-side Media E2EE
// Cifra i file PRIMA dell'upload e li decifra DOPO il download.
// Il server non vede MAI il contenuto in chiaro.
// Uses XChaCha20-Poly1305 (same as backend) via package cryptography.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

class MediaEncryptionService {
  static final Xchacha20 _cipher = Xchacha20.poly1305Aead();

  static const int _nonceLength = 24;
  static const int _macLength = 16;

  /// Generate a random 32-byte file key
  static Future<SecretKey> generateFileKey() async {
    return _cipher.newSecretKey();
  }

  /// Build a SecretKey from raw bytes (e.g. after decrypting file key from ratchet).
  static Future<SecretKey> secretKeyFromBytes(List<int> bytes) async {
    return _cipher.newSecretKeyFromBytes(bytes);
  }

  /// Encrypt file data with XChaCha20-Poly1305.
  /// Returns encrypted bytes: nonce (24) + ciphertext + mac (16)
  static Future<Uint8List> encryptFile(
    Uint8List plaintext,
    SecretKey fileKey,
  ) async {
    final nonce = _cipher.newNonce();
    final secretBox = await _cipher.encrypt(
      plaintext,
      secretKey: fileKey,
      nonce: nonce,
      aad: const [],
    );
    return secretBox.concatenation();
  }

  /// Decrypt file data (format: nonce + ciphertext + mac)
  static Future<Uint8List> decryptFile(
    Uint8List encryptedData,
    SecretKey fileKey,
  ) async {
    final secretBox = SecretBox.fromConcatenation(
      encryptedData,
      nonceLength: _nonceLength,
      macLength: _macLength,
      copy: false,
    );
    final plaintext = await _cipher.decrypt(
      secretBox,
      secretKey: fileKey,
      aad: const [],
    );
    return Uint8List.fromList(plaintext);
  }

  /// Encrypt the file key with the E2EE session key (envelope encryption)
  static Future<String> encryptFileKey(
    SecretKey fileKey,
    SecretKey sessionKey,
  ) async {
    final fileKeyBytes = await fileKey.extractBytes();
    final secretBox = await _cipher.encrypt(
      fileKeyBytes,
      secretKey: sessionKey,
      nonce: _cipher.newNonce(),
      aad: utf8.encode('securechat-file-key'),
    );
    return base64Encode(secretBox.concatenation());
  }

  /// Decrypt the file key with the E2EE session key
  static Future<SecretKey> decryptFileKey(
    String encryptedFileKeyB64,
    SecretKey sessionKey,
  ) async {
    final data = base64Decode(encryptedFileKeyB64);
    final secretBox = SecretBox.fromConcatenation(
      data,
      nonceLength: _nonceLength,
      macLength: _macLength,
      copy: false,
    );
    final fileKeyBytes = await _cipher.decrypt(
      secretBox,
      secretKey: sessionKey,
      aad: utf8.encode('securechat-file-key'),
    );
    return _cipher.newSecretKeyFromBytes(fileKeyBytes);
  }

  /// Encrypt file metadata (filename, mime_type, size, etc.)
  static Future<String> encryptMetadata(
    Map<String, dynamic> metadata,
    SecretKey fileKey,
  ) async {
    final plaintext = utf8.encode(jsonEncode(metadata));
    final secretBox = await _cipher.encrypt(
      plaintext,
      secretKey: fileKey,
      nonce: _cipher.newNonce(),
      aad: utf8.encode('securechat-file-meta'),
    );
    return base64Encode(secretBox.concatenation());
  }

  /// Decrypt file metadata
  static Future<Map<String, dynamic>> decryptMetadata(
    String encryptedMetaB64,
    SecretKey fileKey,
  ) async {
    final data = base64Decode(encryptedMetaB64);
    final secretBox = SecretBox.fromConcatenation(
      data,
      nonceLength: _nonceLength,
      macLength: _macLength,
      copy: false,
    );
    final plaintext = await _cipher.decrypt(
      secretBox,
      secretKey: fileKey,
      aad: utf8.encode('securechat-file-meta'),
    );
    return jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
  }

  /// SHA-256 hash of file data for integrity verification
  static Future<String> computeFileHash(Uint8List data) async {
    final digest = sha256.convert(data);
    return digest.toString();
  }
}
