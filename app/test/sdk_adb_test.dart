import 'package:fire_adb/connection/sdk_adb.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('which 的结果优先于环境变量和常见目录', () {
    final found = resolveSdkAdb(
      windows: true,
      environment: <String, String>{
        'ANDROID_HOME': r'C:\Android\sdk',
        'LOCALAPPDATA': r'C:\Users\Mi\AppData\Local',
      },
      whichOutput: 'D:\\platform-tools\\adb.exe\r\n',
      exists: (path) =>
          path == r'D:\platform-tools\adb.exe' ||
          path == r'C:\Android\sdk\platform-tools\adb.exe',
    );
    expect(found, r'D:\platform-tools\adb.exe');
  });

  test('没有 which 时使用 ANDROID_HOME', () {
    final found = resolveSdkAdb(
      windows: false,
      environment: <String, String>{'ANDROID_HOME': '/opt/android'},
      exists: (path) => path == '/opt/android/platform-tools/adb',
    );
    expect(found, '/opt/android/platform-tools/adb');
  });

  test('环境变量没有时使用各平台常见目录', () {
    final found = resolveSdkAdb(
      windows: true,
      environment: <String, String>{
        'LOCALAPPDATA': r'C:\Users\Mi\AppData\Local',
      },
      exists: (path) =>
          path == r'C:\Users\Mi\AppData\Local\Android\Sdk\platform-tools\adb.exe',
    );
    expect(
      found,
      r'C:\Users\Mi\AppData\Local\Android\Sdk\platform-tools\adb.exe',
    );
  });

  test('都没有时返回空', () {
    expect(
      resolveSdkAdb(
        windows: false,
        environment: const <String, String>{},
        exists: (_) => false,
      ),
      isNull,
    );
  });
}
