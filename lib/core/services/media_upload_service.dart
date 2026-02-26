// SecureChat — Encrypted Media Upload/Download Service
// Flow: 1. Pick file → 2. Encrypt locally → 3. Upload encrypted blob → 4. Send message with encrypted key

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:path/path.dart' as path_lib;

import '../constants/app_constants.dart';
import 'api_service.dart';
import 'media_encryption_service.dart';

class MediaUploadResult {
  final String attachmentId;
  final String encryptedFileUrl;
  final String? encryptedThumbnailUrl;
  final String encryptedFileKeyB64;
  final String encryptedMetadataB64;
  final String fileHash;

  MediaUploadResult({
    required this.attachmentId,
    required this.encryptedFileUrl,
    this.encryptedThumbnailUrl,
    required this.encryptedFileKeyB64,
    required this.encryptedMetadataB64,
    required this.fileHash,
  });
}

class MediaUploadService {
  final ApiService _api = ApiService();

  /// Encrypt file locally → upload encrypted blob → return keys
  Future<MediaUploadResult> encryptAndUpload({
    required Uint8List fileBytes,
    required String fileName,
    required String mimeType,
    required String conversationId,
    required SecretKey sessionKey,
    Uint8List? thumbnailBytes,
    void Function(double progress)? onProgress,
  }) async {
    final fileKey = await MediaEncryptionService.generateFileKey();
    final fileHash = await MediaEncryptionService.computeFileHash(fileBytes);

    onProgress?.call(0.1);
    final encryptedFile =
        await MediaEncryptionService.encryptFile(fileBytes, fileKey);
    onProgress?.call(0.3);

    Uint8List? encryptedThumbnail;
    if (thumbnailBytes != null) {
      encryptedThumbnail =
          await MediaEncryptionService.encryptFile(thumbnailBytes, fileKey);
    }

    final encryptedFileKeyB64 =
        await MediaEncryptionService.encryptFileKey(fileKey, sessionKey);

    final metadata = {
      'filename': fileName,
      'mime_type': mimeType,
      'file_size': fileBytes.length,
      'encrypted_size': encryptedFile.length,
    };
    final encryptedMetadataB64 =
        await MediaEncryptionService.encryptMetadata(metadata, fileKey);

    onProgress?.call(0.4);

    final uri = Uri.parse('${AppConstants.baseUrl}/chat/media/upload/');
    final request = http.MultipartRequest('POST', uri);

    if (_api.accessToken != null) {
      request.headers['Authorization'] = 'Bearer ${_api.accessToken}';
    }

    request.files.add(http.MultipartFile.fromBytes(
      'encrypted_file',
      encryptedFile,
      filename: 'encrypted_${path_lib.basename(fileName)}',
      contentType: MediaType('application', 'octet-stream'),
    ));

    if (encryptedThumbnail != null) {
      request.files.add(http.MultipartFile.fromBytes(
        'encrypted_thumbnail',
        encryptedThumbnail,
        filename: 'encrypted_thumb',
        contentType: MediaType('application', 'octet-stream'),
      ));
    }

    request.fields['conversation_id'] = conversationId;
    request.fields['encrypted_file_key'] = encryptedFileKeyB64;
    request.fields['encrypted_metadata'] = encryptedMetadataB64;
    request.fields['file_hash'] = fileHash;
    request.fields['encrypted_file_size'] = fileBytes.length.toString();

    onProgress?.call(0.6);

    final streamedResponse = await request.send();
    final responseBody = await streamedResponse.stream.bytesToString();

    onProgress?.call(0.9);

    if (streamedResponse.statusCode != 201) {
      throw Exception(
        'Upload failed: ${streamedResponse.statusCode} — $responseBody',
      );
    }

    final data = jsonDecode(responseBody) as Map<String, dynamic>;

    onProgress?.call(1.0);

    return MediaUploadResult(
      attachmentId: data['attachment_id'] as String,
      encryptedFileUrl: (data['encrypted_file_url'] as String?) ?? '',
      encryptedThumbnailUrl: data['encrypted_thumbnail_url'] as String?,
      encryptedFileKeyB64: encryptedFileKeyB64,
      encryptedMetadataB64: encryptedMetadataB64,
      fileHash: fileHash,
    );
  }

  /// Download and decrypt a media file
  Future<DecryptedMedia> downloadAndDecrypt({
    required String attachmentId,
    required SecretKey sessionKey,
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.1);
    final keyResponse = await _api.get('/chat/media/$attachmentId/key/');

    final encryptedFileKeyB64 =
        keyResponse['encrypted_file_key'] as String;
    final encryptedMetadataB64 =
        keyResponse['encrypted_metadata'] as String;
    final expectedHash = keyResponse['file_hash'] as String? ?? '';

    final fileKey = await MediaEncryptionService.decryptFileKey(
      encryptedFileKeyB64,
      sessionKey,
    );

    final metadata = await MediaEncryptionService.decryptMetadata(
      encryptedMetadataB64,
      fileKey,
    );

    onProgress?.call(0.3);

    final downloadUrl =
        '${AppConstants.baseUrl}/chat/media/$attachmentId/download/';
    final headers = _api.accessToken != null
        ? {'Authorization': 'Bearer ${_api.accessToken}'}
        : <String, String>{};
    var downloadResponse = await http.get(Uri.parse(downloadUrl), headers: headers);

    if (downloadResponse.statusCode != 200) {
      throw Exception('Download failed: ${downloadResponse.statusCode}');
    }

    Uint8List encryptedBytes;
    final contentType =
        downloadResponse.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.contains('application/json')) {
      final json = jsonDecode(downloadResponse.body) as Map<String, dynamic>;
      final redirectUrl = json['download_url'] as String?;
      if (redirectUrl == null) {
        throw Exception('Download response missing download_url');
      }
      final redirectResponse = await http.get(Uri.parse(redirectUrl), headers: headers);
      if (redirectResponse.statusCode != 200) {
        throw Exception('Download failed: ${redirectResponse.statusCode}');
      }
      encryptedBytes = Uint8List.fromList(redirectResponse.bodyBytes);
    } else {
      encryptedBytes = Uint8List.fromList(downloadResponse.bodyBytes);
    }

    onProgress?.call(0.7);

    final decryptedBytes = await MediaEncryptionService.decryptFile(
      Uint8List.fromList(encryptedBytes),
      fileKey,
    );

    onProgress?.call(0.9);

    if (expectedHash.isNotEmpty) {
      final actualHash =
          await MediaEncryptionService.computeFileHash(decryptedBytes);
      if (actualHash != expectedHash) {
        throw Exception(
          'File integrity check failed! Expected: $expectedHash, Got: $actualHash',
        );
      }
    }

    onProgress?.call(1.0);

    return DecryptedMedia(
      bytes: decryptedBytes,
      filename: metadata['filename'] as String? ?? 'file',
      mimeType: metadata['mime_type'] as String? ?? 'application/octet-stream',
      originalSize: metadata['file_size'] as int? ?? decryptedBytes.length,
    );
  }

  /// Download and decrypt thumbnail only (fast preview)
  Future<Uint8List?> downloadAndDecryptThumbnail({
    required String attachmentId,
    required SecretKey fileKey,
  }) async {
    try {
      final thumbUrl =
          '${AppConstants.baseUrl}/chat/media/$attachmentId/thumbnail/';
      final response = await http.get(
        Uri.parse(thumbUrl),
        headers: _api.accessToken != null
            ? {'Authorization': 'Bearer ${_api.accessToken}'}
            : {},
      );

      if (response.statusCode != 200) return null;

      return await MediaEncryptionService.decryptFile(
        Uint8List.fromList(response.bodyBytes),
        fileKey,
      );
    } catch (_) {
      return null;
    }
  }
}

class DecryptedMedia {
  final Uint8List bytes;
  final String filename;
  final String mimeType;
  final int originalSize;

  DecryptedMedia({
    required this.bytes,
    required this.filename,
    required this.mimeType,
    required this.originalSize,
  });

  bool get isImage => mimeType.startsWith('image/');
  bool get isVideo => mimeType.startsWith('video/');
  bool get isAudio => mimeType.startsWith('audio/');
}
