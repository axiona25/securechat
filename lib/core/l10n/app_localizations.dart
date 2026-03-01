import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppLocalizations {
  final Locale locale;
  late Map<String, String> _localizedStrings;

  AppLocalizations(this.locale);

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  // Lingue supportate
  static const List<Map<String, String>> supportedLanguages = [
    {'code': 'it', 'name': 'Italiano', 'flag': '🇮🇹'},
    {'code': 'en', 'name': 'English', 'flag': '🇬🇧'},
    {'code': 'es', 'name': 'Español', 'flag': '🇪🇸'},
    {'code': 'fr', 'name': 'Français', 'flag': '🇫🇷'},
    {'code': 'de', 'name': 'Deutsch', 'flag': '🇩🇪'},
    {'code': 'pt', 'name': 'Português', 'flag': '🇵🇹'},
    {'code': 'ru', 'name': 'Русский', 'flag': '🇷🇺'},
    {'code': 'zh', 'name': '中文', 'flag': '🇨🇳'},
    {'code': 'ja', 'name': '日本語', 'flag': '🇯🇵'},
    {'code': 'ar', 'name': 'العربية', 'flag': '🇸🇦'},
    {'code': 'ko', 'name': '한국어', 'flag': '🇰🇷'},
    {'code': 'hi', 'name': 'हिन्दी', 'flag': '🇮🇳'},
    {'code': 'tr', 'name': 'Türkçe', 'flag': '🇹🇷'},
    {'code': 'pl', 'name': 'Polski', 'flag': '🇵🇱'},
    {'code': 'nl', 'name': 'Nederlands', 'flag': '🇳🇱'},
    {'code': 'ro', 'name': 'Română', 'flag': '🇷🇴'},
  ];

  static List<Locale> get supportedLocales =>
      supportedLanguages.map((l) => Locale(l['code']!)).toList();

  Future<bool> load() async {
    String jsonString;
    try {
      jsonString = await rootBundle.loadString('assets/l10n/${locale.languageCode}.json');
    } catch (e) {
      // Fallback to Italian
      jsonString = await rootBundle.loadString('assets/l10n/it.json');
    }
    Map<String, dynamic> jsonMap = json.decode(jsonString);
    _localizedStrings = jsonMap.map((key, value) => MapEntry(key, value.toString()));
    return true;
  }

  String t(String key, [Map<String, String>? params]) {
    String text = _localizedStrings[key] ?? key;
    if (params != null) {
      params.forEach((k, v) {
        text = text.replaceAll('{$k}', v);
      });
    }
    return text;
  }

  // Salva lingua selezionata
  static Future<void> setLanguage(String langCode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_language', langCode);
  }

  // Carica lingua salvata
  static Future<String> getLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('app_language') ?? 'it';
  }
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return AppLocalizations.supportedLanguages.any((l) => l['code'] == locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    AppLocalizations localizations = AppLocalizations(locale);
    await localizations.load();
    return localizations;
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
