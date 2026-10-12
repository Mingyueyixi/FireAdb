import 'package:fire_adb/log/log_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('各平台日志目录都能被文件管理器打开', () {
    expect(
      logDirectoryPathFor(
        operatingSystem: 'windows',
        environment: <String, String>{
          'APPDATA': r'C:\Users\Mi\AppData\Roaming',
        },
      ),
      r'C:\Users\Mi\AppData\Roaming\FireAdb\logs',
    );
    expect(
      logDirectoryPathFor(
        operatingSystem: 'windows',
        environment: <String, String>{'USERPROFILE': r'C:\Users\Mi'},
      ),
      r'C:\Users\Mi\AppData\Roaming\FireAdb\logs',
    );
    expect(
      logDirectoryPathFor(
        operatingSystem: 'linux',
        environment: const <String, String>{'HOME': '/home/mi'},
      ),
      '/home/mi/.local/share/com.fire.adb/logs',
    );
    expect(
      logDirectoryPathFor(
        operatingSystem: 'linux',
        environment: const <String, String>{
          'HOME': '/home/mi',
          'XDG_DATA_HOME': '/home/mi/data',
        },
      ),
      '/home/mi/data/com.fire.adb/logs',
    );
    expect(
      logDirectoryPathFor(
        operatingSystem: 'macos',
        environment: const <String, String>{'HOME': '/Users/Mi'},
      ),
      '/Users/Mi/Library/Application Support/com.fire.adb/logs',
    );
  });
}
