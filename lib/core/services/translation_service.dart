import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../constants/app_constants.dart';
import 'api_service.dart';
import 'dart:collection';

/// Servizio di traduzione che usa il backend Argos Translate (on-premise, offline).
/// Il testo viene inviato SOLO al nostro server backend via HTTPS,
/// NON a servizi terzi come Google o Microsoft.
class TranslationService {
  static final TranslationService _instance = TranslationService._internal();
  factory TranslationService() => _instance;
  TranslationService._internal();

  final Map<String, String> _cache = LinkedHashMap<String, String>();
  static const int _maxCacheSize = 500;

  // Lingue supportate dal backend Argos
  static const List<String> supportedLanguages = [
    'it', 'en', 'es', 'fr', 'de', 'pt', 'ru', 'zh', 'ja', 'ar', 'ko', 'hi', 'tr', 'pl', 'nl', 'ro'
  ];

  /// Controlla se una lingua è supportata
  static bool isSupported(String langCode) => supportedLanguages.contains(langCode);

  /// Controlla se il servizio di traduzione è disponibile (backend raggiungibile)
  Future<bool> isModelDownloaded(String langCode) async {
    // Argos è sempre disponibile sul backend, non serve download
    return isSupported(langCode);
  }

  /// Non serve scaricare modelli con Argos backend
  Future<bool> downloadModel(String langCode) async {
    return isSupported(langCode);
  }

  /// Non serve eliminare modelli
  Future<bool> deleteModel(String langCode) async {
    return true;
  }

  bool get isDownloading => false;

  /// Traduce il testo usando il backend Argos Translate
  Future<String?> translate(String text, String targetLangCode, {String? sourceLangCode}) async {
    if (text.trim().isEmpty) return null;
    if (!isSupported(targetLangCode)) return null;
    if (text.length < 2) return null;

    // Cache check
    final cacheKey = '${sourceLangCode ?? 'auto'}:$targetLangCode:$text';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey];

    try {
      final token = ApiService().accessToken;
      if (token == null) return null;

      final response = await http.post(
        Uri.parse('${AppConstants.baseUrl}/translation/translate/'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'text': text,
          'target_lang': targetLangCode,
          if (sourceLangCode != null) 'source_lang': sourceLangCode,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final translatedText = data['translated_text']?.toString();
        final detectedSource = data['source_language']?.toString() ?? '';

        if (translatedText == null || translatedText.isEmpty) return null;

        // Non restituire se è uguale all'originale
        if (translatedText.toLowerCase().trim() == text.toLowerCase().trim()) return null;

        // Non restituire se source == target (stessa lingua)
        if (detectedSource == targetLangCode) return null;

        // Salva in cache
        if (_cache.length >= _maxCacheSize) {
          _cache.remove(_cache.keys.first);
        }
        _cache[cacheKey] = translatedText;

        return translatedText;
      }
      return null;
    } catch (e) {
      debugPrint('Translation error: $e');
      return null;
    }
  }

  /// Svuota la cache
  void dispose() {
    _cache.clear();
  }
}
