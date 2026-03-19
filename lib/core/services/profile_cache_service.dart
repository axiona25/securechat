import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class ProfileCacheService {
  ProfileCacheService._();
  static final instance = ProfileCacheService._();

  static const _key = 'cached_user_profile';
  Map<String, dynamic>? _memoryCache;

  /// Salva il profilo in memoria e su disco
  Future<void> save(Map<String, dynamic> profile) async {
    _memoryCache = Map<String, dynamic>.from(profile);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(profile));
    } catch (_) {}
  }

  /// Carica il profilo: prima dalla memoria, poi da disco
  Future<Map<String, dynamic>?> load() async {
    if (_memoryCache != null) return _memoryCache;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        _memoryCache = jsonDecode(raw) as Map<String, dynamic>;
        return _memoryCache;
      }
    } catch (_) {}
    return null;
  }

  /// Pulisce la cache (da chiamare al logout)
  Future<void> clear() async {
    _memoryCache = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}
