import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'app_locale_controller.dart';
import 'app_shell/app_shell.dart';
import 'apps/data/source/fire_app_service.dart';
import 'connection/connection_manager.dart';
import 'home/home_controller.dart';
import 'l10n/generated/fire_adb_localizations.dart';
import 'log/app_log.dart';
import 'settings/app_settings_store.dart';
import 'settings/settings_page.dart';
import 'shell/device_root.dart';
import 'shell/device_root_store.dart';
import 'workspace/device_disconnect_ui.dart';
import 'workspace/workspace_controller.dart';
import 'workspace/workspace_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await installAppLogger();
  final manager = ConnectionManager();
  await manager.init();
  await manager.ensureLocalAdbServer();
  Get.put<ConnectionManager>(manager, permanent: true);
  final localeController = AppLocaleController();
  await localeController.load();
  Get.put<AppLocaleController>(localeController, permanent: true);
  final settings = AppSettingsStore();
  await settings.load();
  try {
    await pruneExpiredLogs(settings.logRetentionDays.value);
  } catch (error, stackTrace) {
    log.severe('清理过期日志失败', error, stackTrace);
  }
  Get.put<AppSettingsStore>(settings, permanent: true);
  final deviceRoot = DeviceRootStore();
  await deviceRoot.load();
  Get.put<DeviceRootStore>(deviceRoot, permanent: true);
  manager.afterConnect = activateSavedAdbRoot;
  manager.afterDisconnect = releaseFireAppService;
  manager.onUnexpectedDisconnect = (serial) {
    unawaited(handleUnexpectedDeviceDisconnect(serial));
  };
  Get.put<HomeController>(HomeController(), permanent: true);
  runApp(const FireAdbApp());
}

class FireAdbApp extends StatelessWidget {
  const FireAdbApp({super.key});

  @override
  Widget build(BuildContext context) {
    final localeController = Get.find<AppLocaleController>();
    return GetMaterialApp(
      title: 'FireAdb',
      debugShowCheckedModeBanner: false,
      locale: localeController.locale.value,
      supportedLocales: FireAdbLocalizations.supportedLocales,
      localizationsDelegates: FireAdbLocalizations.localizationsDelegates,
      builder: (context, child) => Obx(
        () => Localizations.override(
          context: context,
          locale: localeController.locale.value,
          delegates: FireAdbLocalizations.localizationsDelegates,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
      ),
      initialRoute: '/',
      getPages: <GetPage<void>>[
        GetPage<void>(name: '/', page: () => const AppShell()),
        GetPage<void>(name: '/settings', page: () => const SettingsPage()),
        GetPage<void>(
          name: '/workspace',
          page: () => const WorkspacePage(),
          binding: BindingsBuilder(() {
            Get.lazyPut<WorkspaceController>(
              () => WorkspaceController(Get.arguments as String),
            );
          }),
        ),
      ],
    );
  }
}
