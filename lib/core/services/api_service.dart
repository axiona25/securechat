import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../constants/app_constants.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  final Map<String, dynamic>? errors;

  ApiException({
    required this.statusCode,
    required this.message,
    this.errors,
  });

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  String? _accessToken;
  String? _refreshToken;

  void setTokens({required String access, required String refresh}) {
    _accessToken = access;
    _refreshToken = refresh;
  }

  void clearTokens() {
    _accessToken = null;
    _refreshToken = null;
  }

  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;
  bool get isAuthenticated => _accessToken != null;

  Map<String, String> get _headers {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (_accessToken != null) {
      headers['Authorization'] = 'Bearer $_accessToken';
    }
    return headers;
  }

  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, dynamic>? body,
    bool requiresAuth = false,
  }) async {
    final url = Uri.parse('${AppConstants.baseUrl}$endpoint');

    try {
      final response = await http.post(
        url,
        headers: _headers,
        body: body != null ? jsonEncode(body) : null,
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return data;
      }

      throw ApiException(
        statusCode: response.statusCode,
        message: data['detail'] ?? data['error'] ?? 'Request failed',
        errors: data['errors'] as Map<String, dynamic>?,
      );
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(
        statusCode: 0,
        message: 'Connection error. Please check your internet.',
      );
    }
  }

  Future<Map<String, dynamic>> put(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final url = Uri.parse('${AppConstants.baseUrl}$endpoint');
    try {
      final response = await http.put(
        url,
        headers: _headers,
        body: body != null ? jsonEncode(body) : null,
      );
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return data;
      }
      throw ApiException(
        statusCode: response.statusCode,
        message: data['detail'] ?? data['error'] ?? 'Request failed',
        errors: data['errors'] as Map<String, dynamic>?,
      );
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(
        statusCode: 0,
        message: 'Connection error. Please check your internet.',
      );
    }
  }

  Future<Map<String, dynamic>> patch(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final url = Uri.parse('${AppConstants.baseUrl}$endpoint');
    try {
      final response = await http.patch(
        url,
        headers: _headers,
        body: body != null ? jsonEncode(body) : null,
      );
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return data;
      }
      throw ApiException(
        statusCode: response.statusCode,
        message: data['detail'] ?? data['error'] ?? 'Request failed',
        errors: data['errors'] as Map<String, dynamic>?,
      );
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(
        statusCode: 0,
        message: 'Connection error. Please check your internet.',
      );
    }
  }

  Future<Map<String, dynamic>> delete(String endpoint) async {
    final url = Uri.parse('${AppConstants.baseUrl}$endpoint');
    try {
      final response = await http.delete(url, headers: _headers);
      final data = response.body.isNotEmpty
          ? (jsonDecode(response.body) as Map<String, dynamic>)
          : <String, dynamic>{};
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return data;
      }
      throw ApiException(
        statusCode: response.statusCode,
        message: data['detail'] ?? data['error'] ?? 'Request failed',
      );
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(
        statusCode: 0,
        message: 'Connection error. Please check your internet.',
      );
    }
  }

  Future<Map<String, dynamic>> get(
    String endpoint, {
    Map<String, String>? queryParams,
  }) async {
    var url = Uri.parse('${AppConstants.baseUrl}$endpoint');
    if (queryParams != null) {
      url = url.replace(queryParameters: queryParams);
    }

    try {
      final response = await http.get(url, headers: _headers);
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return data;
      }

      throw ApiException(
        statusCode: response.statusCode,
        message: data['detail'] ?? 'Request failed',
      );
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(
        statusCode: 0,
        message: 'Connection error. Please check your internet.',
      );
    }
  }

  /// POST multipart file to /api/media/upload/ (field name: file). Returns response map (e.g. url, id).
  Future<Map<String, dynamic>> uploadFile(File file) async {
    final uri = Uri.parse('${AppConstants.baseUrl}/media/upload/');
    final request = http.MultipartRequest('POST', uri);
    if (_accessToken != null) {
      request.headers['Authorization'] = 'Bearer $_accessToken';
    }
    request.headers['Accept'] = 'application/json';
    request.files.add(await http.MultipartFile.fromPath('file', file.path));
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return data;
    }
    throw ApiException(
      statusCode: response.statusCode,
      message: data['detail'] ?? data['error'] ?? 'Upload failed',
      errors: data['errors'] as Map<String, dynamic>?,
    );
  }

  /// POST multipart file to /api/chat/upload/ (field name: file). Returns response map (url, id, etc.).
  Future<Map<String, dynamic>> uploadChatFile(
    File file, {
    String? filename,
    MediaType? contentType,
  }) async {
    final uri = Uri.parse('${AppConstants.baseUrl}/chat/upload/');
    final request = http.MultipartRequest('POST', uri);
    if (_accessToken != null) {
      request.headers['Authorization'] = 'Bearer $_accessToken';
    }
    request.headers['Accept'] = 'application/json';
    final name = filename ?? file.path.split(RegExp(r'[/\\]')).last;
    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        file.path,
        filename: name,
        contentType: contentType,
      ),
    );
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return data;
    }
    throw ApiException(
      statusCode: response.statusCode,
      message: data['detail'] ?? data['error'] ?? 'Upload failed',
      errors: data['errors'] as Map<String, dynamic>?,
    );
  }

  /// GET that returns a JSON array (e.g. search results). Returns empty list on non-2xx.
  Future<List<dynamic>> getList(
    String endpoint, {
    Map<String, String>? queryParams,
  }) async {
    var url = Uri.parse('${AppConstants.baseUrl}$endpoint');
    if (queryParams != null) {
      url = url.replace(queryParameters: queryParams);
    }
    try {
      final response = await http.get(url, headers: _headers);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          statusCode: response.statusCode,
          message: 'Request failed',
        );
      }
      final data = jsonDecode(response.body);
      if (data is List) return data;
      return [];
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(
        statusCode: 0,
        message: 'Connection error. Please check your internet.',
      );
    }
  }
}
