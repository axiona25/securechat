import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import '../constants/app_constants.dart';
import 'api_service.dart';
import 'permission_service.dart';

class PickedMedia {
  final File file;
  final String fileName;
  final String mimeType;
  final int fileSize;
  final String messageType;

  PickedMedia({
    required this.file,
    required this.fileName,
    required this.mimeType,
    required this.fileSize,
    required this.messageType,
  });

  String get fileSizeFormatted {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(0)} KB';
    return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

typedef UploadProgressCallback = void Function(double progress);

class MediaService {
  static final MediaService _instance = MediaService._internal();
  factory MediaService() => _instance;
  MediaService._internal();

  final ImagePicker _imagePicker = ImagePicker();
  final ApiService _api = ApiService();

  Future<PickedMedia?> pickImageFromGallery({int quality = 80}) async {
    final granted = await PermissionService.requestStorage();
    if (!granted) return null;

    final XFile? picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: quality,
      maxWidth: 1920,
      maxHeight: 1920,
    );

    if (picked == null) return null;
    return _xFileToPickedMedia(picked, 'image');
  }

  Future<PickedMedia?> pickImageFromCamera({int quality = 80}) async {
    final granted = await PermissionService.requestCamera();
    if (!granted) return null;

    final XFile? picked = await _imagePicker.pickImage(
      source: ImageSource.camera,
      imageQuality: quality,
      maxWidth: 1920,
      maxHeight: 1920,
    );

    if (picked == null) return null;
    return _xFileToPickedMedia(picked, 'image');
  }

  Future<PickedMedia?> pickVideoFromGallery({Duration? maxDuration}) async {
    final granted = await PermissionService.requestStorage();
    if (!granted) return null;

    final XFile? picked = await _imagePicker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: maxDuration ?? const Duration(minutes: 5),
    );

    if (picked == null) return null;
    return _xFileToPickedMedia(picked, 'video');
  }

  Future<PickedMedia?> pickVideoFromCamera({Duration? maxDuration}) async {
    final camGranted = await PermissionService.requestCamera();
    final micGranted = await PermissionService.requestMicrophone();
    if (!camGranted || !micGranted) return null;

    final XFile? picked = await _imagePicker.pickVideo(
      source: ImageSource.camera,
      maxDuration: maxDuration ?? const Duration(minutes: 5),
    );

    if (picked == null) return null;
    return _xFileToPickedMedia(picked, 'video');
  }

  Future<PickedMedia?> pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
      withReadStream: false,
    );

    if (result == null || result.files.isEmpty) return null;

    final platformFile = result.files.first;
    if (platformFile.path == null) return null;

    final file = File(platformFile.path!);
    final mimeType = lookupMimeType(platformFile.name) ?? 'application/octet-stream';

    return PickedMedia(
      file: file,
      fileName: platformFile.name,
      mimeType: mimeType,
      fileSize: platformFile.size,
      messageType: 'file',
    );
  }

  Future<List<PickedMedia>> pickMultipleImages({int quality = 80}) async {
    final granted = await PermissionService.requestStorage();
    if (!granted) return [];

    final List<XFile> picked = await _imagePicker.pickMultiImage(
      imageQuality: quality,
      maxWidth: 1920,
      maxHeight: 1920,
    );

    final List<PickedMedia> result = [];
    for (final xFile in picked) {
      final media = await _xFileToPickedMedia(xFile, 'image');
      if (media != null) result.add(media);
    }
    return result;
  }

  Future<Map<String, dynamic>> uploadMediaMessage({
    required String conversationId,
    required File file,
    required String messageType,
    String? content,
    String? metadata,
    UploadProgressCallback? onProgress,
  }) async {
    final uri = Uri.parse(
      '${AppConstants.baseUrl}/chat/conversations/$conversationId/messages/',
    );

    final request = http.MultipartRequest('POST', uri);

    if (_api.accessToken != null) {
      request.headers['Authorization'] = 'Bearer ${_api.accessToken}';
    }

    request.fields['message_type'] = messageType;
    if (content != null && content.isNotEmpty) {
      request.fields['content'] = content;
    }
    if (metadata != null) {
      request.fields['metadata'] = metadata;
    }

    final fileName = p.basename(file.path);
    final mimeType = lookupMimeType(fileName) ?? 'application/octet-stream';
    final mimeTypeParts = mimeType.split('/');

    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        file.path,
        filename: fileName,
        contentType: MediaType(
          mimeTypeParts[0],
          mimeTypeParts.length > 1 ? mimeTypeParts[1] : 'octet-stream',
        ),
      ),
    );

    final streamedResponse = await request.send();

    int sentBytes = 0;
    final totalBytes = file.lengthSync();

    final responseBytes = <int>[];
    await for (final chunk in streamedResponse.stream) {
      responseBytes.addAll(chunk);
      sentBytes += chunk.length;
      onProgress?.call(totalBytes > 0 ? sentBytes / totalBytes : 1.0);
    }

    final responseBody = String.fromCharCodes(responseBytes);

    if (streamedResponse.statusCode >= 200 && streamedResponse.statusCode < 300) {
      try {
        if (responseBody.trim().isEmpty) return {'success': true};
        return Map<String, dynamic>.from(jsonDecode(responseBody) as Map);
      } catch (_) {
        return {'success': true};
      }
    }

    throw ApiException(
      statusCode: streamedResponse.statusCode,
      message: 'Upload failed: ${streamedResponse.statusCode}',
    );
  }

  Future<PickedMedia?> _xFileToPickedMedia(XFile xFile, String type) async {
    final file = File(xFile.path);
    final stat = await file.stat();
    final mimeType = lookupMimeType(xFile.name) ?? 'application/$type';

    return PickedMedia(
      file: file,
      fileName: xFile.name,
      mimeType: mimeType,
      fileSize: stat.size,
      messageType: type,
    );
  }
}
