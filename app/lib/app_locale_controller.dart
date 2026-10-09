import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppLanguage {
  const AppLanguage(this.locale, this.nativeName);

  final Locale locale;
  final String nativeName;
}

class AppLocaleController extends GetxController {
  static const String _preferenceKey = 'appLocale';
  static const List<AppLanguage> languages = <AppLanguage>[
    AppLanguage(Locale('zh'), '中文'),
    AppLanguage(Locale('en'), 'English'),
  ];

  static List<Locale> get supportedLocales => <Locale>[
    for (final language in languages) language.locale,
  ];

  String nativeNameOf(Locale locale) {
    for (final language in languages) {
      if (language.locale == locale) return language.nativeName;
    }
    return languages.first.nativeName;
  }

  final Rx<Locale> locale = const Locale('zh').obs;

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    final languageCode = preferences.getString(_preferenceKey);
    if (languageCode == null) return;
    locale.value = supportedLocales.firstWhere(
      (supportedLocale) => supportedLocale.languageCode == languageCode,
      orElse: () => const Locale('zh'),
    );
  }

  Future<void> setLocale(Locale newLocale) async {
    if (!supportedLocales.contains(newLocale)) {
      throw ArgumentError.value(newLocale, 'newLocale', 'Unsupported locale');
    }
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setString(
      _preferenceKey,
      newLocale.languageCode,
    );
    if (!saved) {
      throw StateError('Could not save the application language');
    }
    locale.value = newLocale;
  }
}
