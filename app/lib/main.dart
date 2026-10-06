import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'connection/connection_manager.dart';
import 'home/home_controller.dart';
import 'home/home_page.dart';
import 'workspace/workspace_controller.dart';
import 'workspace/workspace_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final manager = ConnectionManager();
  await manager.init();
  Get.put<ConnectionManager>(manager, permanent: true);
  Get.put<HomeController>(HomeController(), permanent: true);
  runApp(const FireAdbApp());
}

class FireAdbApp extends StatelessWidget {
  const FireAdbApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'FireAdb',
      debugShowCheckedModeBanner: false,
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
