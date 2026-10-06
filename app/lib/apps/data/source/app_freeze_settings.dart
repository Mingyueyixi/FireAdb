import 'package:shared_preferences/shared_preferences.dart';

import '../bean/app_freeze.dart';

class AppFreezeSettings {
  AppFreezeSettings._();

  static const String _preferenceKey = 'appsFreezeMethod';

  static Future<AppFreezeMethod> loadMethod() async {
    final preferences = await SharedPreferences.getInstance();
    return AppFreezeMethodCommands.fromId(
      preferences.getString(_preferenceKey),
    );
  }

  static Future<void> saveMethod(AppFreezeMethod method) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_preferenceKey, method.id);
  }
}
