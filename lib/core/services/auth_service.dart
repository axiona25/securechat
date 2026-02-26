import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';
import 'api_service.dart';
import 'crypto_service.dart';
import 'session_manager.dart';

const String _keyCurrentUserId = 'current_user_id';

class AuthResult {
  final bool success;
  final String? error;
  final String? accessToken;
  final String? refreshToken;
  final Map<String, dynamic>? fieldErrors;

  AuthResult({
    required this.success,
    this.error,
    this.accessToken,
    this.refreshToken,
    this.fieldErrors,
  });
}

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final ApiService _api = ApiService();

  bool get isLoggedIn => _api.isAuthenticated;

  Future<AuthResult> login({
    required String email,
    required String password,
  }) async {
    try {
      final data = await _api.post('/auth/login/', body: {
        'email': email,
        'password': password,
      });

      final access = data['access'] as String?;
      final refresh = data['refresh'] as String?;

      if (access != null && refresh != null) {
        _api.setTokens(access: access, refresh: refresh);
        final user = data['user'] as Map<String, dynamic>?;
        final userId = user?['id'];
        if (userId != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt(_keyCurrentUserId, userId is int ? userId : int.tryParse(userId.toString()) ?? 0);
        }
        // Initialize E2E encryption keys (idempotent; does not block login on failure)
        try {
          print('[Auth] Starting crypto key initialization...');
          final keysOk = await CryptoService(apiService: _api).initializeKeys();
          print('[Auth] Crypto init result: $keysOk');
        } catch (e, stack) {
          print('[Auth] Crypto init FAILED: $e');
          print('[Auth] Stack: $stack');
        }
        return AuthResult(
          success: true,
          accessToken: access,
          refreshToken: refresh,
        );
      }

      return AuthResult(
        success: false,
        error: 'Invalid response from server.',
      );
    } on ApiException catch (e) {
      String errorMsg;
      if (e.statusCode == 401) {
        errorMsg = 'Invalid email or password.';
      } else if (e.statusCode == 0) {
        errorMsg = e.message;
      } else {
        errorMsg = e.message;
      }
      return AuthResult(success: false, error: errorMsg);
    }
  }

  Future<AuthResult> register({
    required String fullName,
    required String email,
    required String password,
    required String passwordConfirm,
  }) async {
    try {
      final username = fullName.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_');
      final nameParts = fullName.trim().split(' ');
      final firstName = nameParts.first;
      final lastName = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';

      await _api.post('/auth/register/', body: {
        'username': username,
        'email': email,
        'password': password,
        'password_confirm': passwordConfirm,
        'first_name': firstName,
        'last_name': lastName,
      });

      return await login(email: email, password: password);
    } on ApiException catch (e) {
      Map<String, dynamic>? fieldErrors;
      if (e.errors != null) {
        fieldErrors = e.errors;
      }

      String errorMsg;
      if (e.statusCode == 400) {
        if (fieldErrors != null && fieldErrors.isNotEmpty) {
          final firstField = fieldErrors.keys.first;
          final firstError = fieldErrors[firstField];
          if (firstError is List && firstError.isNotEmpty) {
            errorMsg = firstError.first.toString();
          } else {
            errorMsg = firstError.toString();
          }
        } else {
          errorMsg = e.message;
        }
      } else if (e.statusCode == 0) {
        errorMsg = e.message;
      } else {
        errorMsg = e.message;
      }

      return AuthResult(
        success: false,
        error: errorMsg,
        fieldErrors: fieldErrors,
      );
    }
  }

  Future<AuthResult> requestPasswordReset({required String email}) async {
    try {
      await _api.post('/auth/password/reset/', body: {
        'email': email,
      });
      return AuthResult(success: true);
    } on ApiException catch (e) {
      return AuthResult(success: false, error: e.message);
    }
  }

  /// Logout: clear E2E sessions, wipe keys, notifica backend, cancella token e prefs.
  Future<void> logout() async {
    try {
      final sessionMgr = SessionManager(
        apiService: _api,
        cryptoService: CryptoService(apiService: _api),
      );
      await sessionMgr.clearAllSessions();
    } catch (_) {}
    // NON cancellare le chiavi crittografiche al logout:
    // devono persistere per decifrare messaggi precedenti.
    try {
      await _api.post('/auth/logout/', body: {});
    } catch (_) {
      // Procedi comunque con clear locale (es. offline)
    }
    _api.clearTokens();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyCurrentUserId);
  }

  /// Refresh access token using refresh token. Call before authenticated requests
  /// that may run after the access token has expired (e.g. E2E upload/decrypt).
  /// Returns true if token is now valid, false if refresh failed or no refresh token.
  Future<bool> refreshAccessTokenIfNeeded() async {
    final refresh = _api.refreshToken;
    if (refresh == null || refresh.isEmpty) return false;
    try {
      final url = Uri.parse('${AppConstants.baseUrl}/auth/token/refresh/');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
        body: jsonEncode({'refresh': refresh}),
      );
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body) as Map<String, dynamic>?;
      final access = data?['access'] as String?;
      if (access == null || access.isEmpty) return false;
      final newRefresh = data?['refresh'] as String?;
      _api.setTokens(access: access, refresh: newRefresh ?? refresh);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// ID utente loggato (salvato al login). Null se non disponibile.
  static Future<int?> getCurrentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyCurrentUserId);
  }

  /// Salva l'id utente corrente (es. dopo aver caricato il profilo).
  static Future<void> setCurrentUserId(int id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyCurrentUserId, id);
  }
}
