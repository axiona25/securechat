import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../main.dart' show initNotifyForLoggedInUser, securityEnabledNotifier;
import '../constants/app_constants.dart';
import 'api_service.dart';
import 'crypto_service.dart';
import 'device_service.dart';
import 'profile_cache_service.dart';
import 'security_service.dart';
import 'session_manager.dart';
import 'voip_service.dart';
import 'e2e_key_store.dart';

const String _keyCurrentUserId = 'current_user_id';

// Secure storage per JWT tokens
const _tokenStorage = FlutterSecureStorage(
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

Future<void> _saveTokensSecure(String access, String refresh) async {
  await _tokenStorage.write(key: 'access_token', value: access);
  await _tokenStorage.write(key: 'refresh_token', value: refresh);
}

Future<void> _deleteTokensSecure() async {
  await _tokenStorage.delete(key: 'access_token');
  await _tokenStorage.delete(key: 'refresh_token');
}

Future<({String? access, String? refresh})> _readTokensSecure() async {
  final access = await _tokenStorage.read(key: 'access_token');
  final refresh = await _tokenStorage.read(key: 'refresh_token');
  return (access: access, refresh: refresh);
}

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

  Future<void> _remoteLog(String message) async {
    // SECURITY: remote logging disabilitato in release per evitare leak di materiale crittografico
    if (kReleaseMode) return;
    try {
      await _api.post('/encryption/debug/log/', body: {'message': message}, requiresAuth: true);
    } catch (_) {}
  }

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
        await _saveTokensSecure(access, refresh);
        // Rimuovi eventuali token legacy da SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('access_token');
        await prefs.remove('refresh_token');
        // Registra il device
        final deviceOk = await DeviceService.instance.registerDevice();
        if (!deviceOk) {
          _api.clearTokens();
          await _deleteTokensSecure();
          throw ApiException(statusCode: 403, message: 'device_blocked');
        }
        final user = data['user'] as Map<String, dynamic>?;
        final userId = user?['id'];
        if (userId != null) {
          final prefs = await SharedPreferences.getInstance();
          final id = userId is int ? userId : int.tryParse(userId.toString()) ?? 0;
          await prefs.setInt(_keyCurrentUserId, id);
          try {
            await initNotifyForLoggedInUser(id);
            debugPrint('[Auth] Notify inizializzato dopo login (security da preferenze)');
          } catch (e) {
            debugPrint('[Auth] initNotifyForLoggedInUser failed: $e');
          }
          debugPrint('[AuthUser] source=login, currentUserId=$id');
          try {
            final crypto = CryptoService(apiService: _api);
            final e2eStatus = await crypto.ensureE2EReady();
            print('[Auth] E2E status: $e2eStatus');
          } catch (e) {
            print('[Auth] E2E check failed: $e');
          }
        }
        try {
          await SessionManager.autoResetIfNewInstall(_api);
        } catch (e) {
          print('[Auth] Install id update failed: $e');
        }
        // Cancella sessioni E2E solo se le chiavi locali sono cambiate
        // (nuovo dispositivo o reinstallazione). Se le chiavi sono le stesse
        // mantieni le sessioni per preservare la decifratura dei messaggi storici.
        try {
          final prefs = await SharedPreferences.getInstance();
          final storedUserId = prefs.getInt('scp_last_login_user_id');
          final currentUserId = data['user_id'] as int? ?? (data['user'] as Map<String, dynamic>?)?['id'] as int?;
          final keysPresent = await _checkLocalKeysPresent();
          final sameUser = storedUserId != null && storedUserId == currentUserId;
          if (!sameUser || !keysPresent) {
            final sessionMgr = SessionManager(apiService: _api);
            await sessionMgr.clearAllSessions();
            print('[Auth] E2E sessions cleared on login (new user or missing keys)');
          } else {
            print('[Auth] E2E sessions preserved on login (same user, keys intact)');
          }
          await prefs.setInt('scp_last_login_user_id', currentUserId ?? 0);
        } catch (e) {
          print('[Auth] clearAllSessions check failed: $e');
        }
        await VoipService.instance.retryVoipTokenRegistration();
        // Registra APNs token per push messaggi
        try {
          final apnsToken = await getApnsToken();
          if (apnsToken != null) {
            await _api.post('/auth/apns-token/', body: {'apns_token': apnsToken});
            print('[Auth] APNs token registrato');
          }
        } catch (e) {
          print('[Auth] APNs token registration failed: $e');
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
      } else if (e.statusCode == 400) {
        errorMsg = e.message == 'Request failed' ? 'Credenziali non valide' : e.message;
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

      return AuthResult(success: true);
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

  /// Logout: rimuovi token VoIP dal backend, clear E2E sessions, notifica backend, cancella token e prefs.
  Future<void> logout() async {
    try {
      await _api.delete('/auth/voip-token/');
    } catch (_) {}
    try {
      await _api.delete('/auth/apns-token/');
    } catch (_) {}
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
      final refresh = _api.refreshToken;
      await _api.post('/auth/logout/', body: refresh != null ? {'refresh': refresh} : {});
    } catch (_) {
      // Procedi comunque con clear locale (es. offline)
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('access_token');
      await prefs.remove('refresh_token');
      await _deleteTokensSecure();
      _api.clearTokens();
      try {
        final userId = await AuthService.getCurrentUserId();
        if (userId != null) await E2EKeyStore.clearForUser(userId);
      } catch (_) {}
      await prefs.remove(_keyCurrentUserId);
      await ProfileCacheService.instance.clear();
    } finally {
      SecurityService().stopMonitoring();
      securityEnabledNotifier.value = false;
      debugPrint('[Auth] SecurityService fermato al logout');
    }
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
      final validRefresh = newRefresh ?? refresh;
      _api.setTokens(access: access, refresh: validRefresh);
      // Persiste i nuovi token in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('access_token', access);
      await prefs.setString('refresh_token', validRefresh);
      await _saveTokensSecure(access, validRefresh);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// ID utente loggato (salvato al login). Null se non disponibile.
  static Future<int?> getCurrentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getInt(_keyCurrentUserId);
    debugPrint('[AuthUser] source=prefs, currentUserId=$id');
    return id;
  }

  /// Salva l'id utente corrente (es. dopo aver caricato il profilo). Source of truth per runtime.
  static Future<void> setCurrentUserId(int id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyCurrentUserId, id);
    debugPrint('[AuthUser] source=setCurrentUserId, currentUserId=$id');
  }

  Future<bool> _checkLocalKeysPresent() async {
    try {
      const storage = FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
        iOptions: IOSOptions(
          accountName: 'com.axphone.app.e2e',
          accessibility: KeychainAccessibility.first_unlock_this_device,
          groupId: 'F28CW3467A.com.axphone.app.e2e',
        ),
      );
      final identity = await storage.read(key: 'scp_identity_private');
      final identityDh = await storage.read(key: 'scp_identity_dh_private');
      final signedPrekey = await storage.read(key: 'scp_signed_prekey_private');
      return identity != null && identityDh != null && signedPrekey != null;
    } catch (_) {
      return false;
    }
  }

  Future<String?> getApnsToken() async {
    if (!Platform.isIOS) return null;
    try {
      const apnsChannel = MethodChannel('com.axphone.app/apns');
      final token = await apnsChannel.invokeMethod<String>('getApnsToken');
      return token;
    } catch (e) {
      print('[Auth] getAPNSToken error: $e');
    }
    return null;
  }
}
