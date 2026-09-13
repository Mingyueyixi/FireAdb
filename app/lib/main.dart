import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/connection_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final manager = ConnectionManager();
  await manager.init();
  runApp(FireAdbApp(manager: manager));
}

class FireAdbApp extends StatelessWidget {
  const FireAdbApp({super.key, required this.manager});

  final ConnectionManager manager;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FireAdb',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
      ),
      home: HomeScreen(manager: manager),
    );
  }
}