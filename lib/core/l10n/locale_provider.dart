import 'package:flutter/material.dart';
import 'app_localizations.dart';

final localeProvider = LocaleProvider();

class LocaleProvider extends ChangeNotifier {
  Locale _locale = const Locale('it');

  Locale get locale => _locale;

  LocaleProvider() {
    _loadSavedLocale();
  }

  Future<void> _loadSavedLocale() async {
    final langCode = await AppLocalizations.getLanguage();
    _locale = Locale(langCode);
    notifyListeners();
  }

  Future<void> setLocale(Locale locale) async {
    _locale = locale;
    await AppLocalizations.setLanguage(locale.languageCode);
    notifyListeners();
  }
}
