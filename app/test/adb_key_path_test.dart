import 'package:fire_adb/connection/adb_key_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('安卓密钥放在应用私有 files 目录', () {
    expect(
      adbKeyFilePath(
        android: true,
        environment: const <String, String>{},
        androidDataDir: '/data/user/0/com.fire.adb',
        separator: '/',
      ),
      '/data/user/0/com.fire.adb/files/fire_adb/adbkey.pem',
    );
  });

  test('桌面优先使用 HOME', () {
    expect(
      adbKeyFilePath(
        android: false,
        environment: const <String, String>{
          'HOME': '/home/me',
          'USERPROFILE': r'C:\Users\me',
        },
        androidDataDir: '',
        separator: '/',
      ),
      '/home/me/.config/fire_adb/adbkey.pem',
    );
  });

  test('桌面没有 HOME 时使用 USERPROFILE', () {
    expect(
      adbKeyFilePath(
        android: false,
        environment: const <String, String>{'USERPROFILE': r'C:\Users\me'},
        androidDataDir: '',
        separator: r'\',
      ),
      r'C:\Users\me\.config\fire_adb\adbkey.pem',
    );
  });

  test('桌面没有用户目录时无法保存密钥', () {
    expect(
      () => adbKeyFilePath(
        android: false,
        environment: const <String, String>{},
        androidDataDir: '',
      ),
      throwsA(isA<AdbKeyUnavailable>()),
    );
  });
}
