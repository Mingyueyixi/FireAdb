import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app_feedback.dart';
import '../app_locale_controller.dart';
import '../l10n/fire_adb_localizations_ext.dart';

class LocaleSelector extends StatelessWidget {
  const LocaleSelector({super.key});

  Future<void> _selectLocale(BuildContext context, Locale locale) async {
    try {
      await Get.find<AppLocaleController>().setLocale(locale);
    } catch (error, stackTrace) {
      logAppError('Could not save application language', error, stackTrace);
      if (!context.mounted) return;
      final localizations = context.l10n;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: localizations.commonSettingsSaveFailed,
        message: localizations.settingsLanguageSaveFailed('$error'),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = context.l10n;
    final controller = Get.find<AppLocaleController>();
    return Obx(
      () => PopupMenuButton<Locale>(
        tooltip: localizations.settingsLanguage,
        initialValue: controller.locale.value,
        onSelected: (locale) => _selectLocale(context, locale),
        itemBuilder: (context) => <PopupMenuEntry<Locale>>[
          PopupMenuItem<Locale>(
            value: const Locale('zh'),
            child: Text(localizations.settingsChinese),
          ),
          PopupMenuItem<Locale>(
            value: const Locale('en'),
            child: Text(localizations.settingsEnglish),
          ),
        ],
        icon: const Icon(Icons.language),
      ),
    );
  }
}
