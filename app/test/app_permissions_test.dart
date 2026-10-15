import 'package:fire_adb/apps/data/source/app_permissions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parsePackagePermissions 区分运行时权限和安装权限', () {
    const output = '''
Package [com.example.app] (1):
  requested permissions:
    android.permission.INTERNET
    android.permission.CAMERA
    android.permission.READ_CONTACTS
  install permissions:
    android.permission.INTERNET: granted=true
  runtime permissions:
    android.permission.CAMERA: granted=true, flags=[ USER_SET ]
    android.permission.READ_CONTACTS: granted=false, flags=[ USER_SET ]
''';
    final entries = parsePackagePermissions(output);
    final byName = {for (final entry in entries) entry.name: entry};
    expect(byName['android.permission.CAMERA']!.granted, isTrue);
    expect(byName['android.permission.CAMERA']!.changeable, isTrue);
    expect(byName['android.permission.READ_CONTACTS']!.granted, isFalse);
    expect(byName['android.permission.READ_CONTACTS']!.changeable, isTrue);
    expect(byName['android.permission.INTERNET']!.granted, isTrue);
    expect(byName['android.permission.INTERNET']!.changeable, isFalse);
    expect(
      entries.indexWhere((entry) => entry.changeable),
      lessThan(entries.indexWhere((entry) => !entry.changeable)),
    );
  });

  test('parsePackagePermissions 解析分行的 granted', () {
    const output = '''
  runtime permissions:
    android.permission.POST_NOTIFICATIONS:
      granted=true
      flags=[ USER_SET ]
''';
    final entries = parsePackagePermissions(output);
    expect(entries, hasLength(1));
    expect(entries.single.name, 'android.permission.POST_NOTIFICATIONS');
    expect(entries.single.granted, isTrue);
    expect(entries.single.changeable, isTrue);
  });

  test('只在请求列表里的权限不能直接修改', () {
    const output = '''
  requested permissions:
    android.permission.SYSTEM_ALERT_WINDOW
    android.permission.INTERNET
''';
    final entries = parsePackagePermissions(output);
    expect(entries.every((entry) => !entry.changeable), isTrue);
  });

  test('appops 把悬浮窗标成可修改', () {
    final entries = applyAppOps(
      parsePackagePermissions('''
  requested permissions:
    android.permission.SYSTEM_ALERT_WINDOW
'''),
      parseAppOps('SYSTEM_ALERT_WINDOW: allow; time=+1s ago'),
    );
    expect(entries.single.changeable, isTrue);
    expect(entries.single.granted, isTrue);
  });

  test('厂商禁止 shell 授权时能认出来', () {
    expect(
      shellBlockedRuntimeGrant(
        'java.lang.SecurityException: grantRuntimePermission: Neither user 2000 nor current process has android.permission.GRANT_RUNTIME_PERMISSIONS.',
      ),
      isTrue,
    );
    expect(
      shellBlockedRuntimeGrant(
        'java.lang.SecurityException: Permission android.permission.INTERNET is not a changeable permission type',
      ),
      isFalse,
    );
  });

  test('ensurePermissionCommand 只保留异常原文', () {
    ensurePermissionCommand('');
    ensurePermissionCommand('Success');
    const output = '''
Exception occurred while executing 'grant':
java.lang.SecurityException: Permission android.permission.INTERNET is not a changeable permission type
	at com.android.server.pm.permission.PermissionManagerServiceImpl.grantRuntimePermission(PermissionManagerServiceImpl.java:1400)
	at com.android.modules.utils.BasicShellCommandHandler.exec(BasicShellCommandHandler.java:97)
	at android.os.ShellCommand.exec(ShellCommand.java:38)
	at com.android.server.pm.PackageManagerService\$IPackageManagerImpl.onShellCommand(PackageManagerService.java:7234)
''';
    expect(
      () => ensurePermissionCommand(output),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'java.lang.SecurityException: Permission android.permission.INTERNET is not a changeable permission type',
        ),
      ),
    );
  });
}
