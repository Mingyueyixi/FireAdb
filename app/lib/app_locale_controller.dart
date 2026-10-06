import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppLocaleController extends GetxController {
  static const String _preferenceKey = 'appLocale';
  static const List<Locale> supportedLocales = <Locale>[
    Locale('zh'),
    Locale('en'),
  ];

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
