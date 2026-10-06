import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'app_locale_controller.dart';
import 'connection/connection_manager.dart';
import 'home/home_controller.dart';
import 'home/home_page.dart';
import 'l10n/generated/fire_adb_localizations.dart';
import 'workspace/workspace_controller.dart';
import 'workspace/workspace_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final manager = ConnectionManager();
  await manager.init();
  Get.put<ConnectionManager>(manager, permanent: true);
  final localeController = AppLocaleController();
  await localeController.load();
  Get.put<AppLocaleController>(localeController, permanent: true);
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
        GetPage<void>(
          name: '/',
          page: () => const HomePage(),
        ),
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
