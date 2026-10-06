import 'package:fire_adb/apps/app_inventory.dart';
import 'package:fire_adb/apps/installed_app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parsePmListPackages 解析带路径的包列表', () {
    const output = '''
package:/data/app/~~abc==/com.example.app-xyz/base.apk=com.example.app
package:/system/priv-app/Settings/Settings.apk=com.android.settings
package:com.broken
''';
    final apps = parsePmListPackages(output, withPath: true);
    expect(apps['com.example.app']!.primaryPath, endsWith('base.apk'));
    expect(apps['com.android.settings']!.primaryPath, contains('Settings.apk'));
    expect(apps['com.broken']!.apkPaths, isEmpty);
  });

  test('parseDumpsysPackages 提取版本、系统标记与冻结状态', () {
    const output = '''
Packages:
  Package [com.example.app] (abc):
    userId=10123
    codePath=/data/app/~~abc==/com.example.app-xyz
    versionCode=12 minSdk=24 targetSdk=34
    versionName=1.2.3
    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]
    applicationLabel=示例应用
    User 0: ceDataInode=1 installed=true hidden=false enabled=0
  Package [com.android.settings] (def):
    codePath=/system/priv-app/Settings
    versionCode=34 minSdk=34 targetSdk=34
    versionName=14
    pkgFlags=[ SYSTEM HAS_CODE ]
    User 0: ceDataInode=2 installed=true hidden=false enabled=3
  Package [com.example.paused] (ghi):
    codePath=/data/app/paused
    versionName=1.0
    flags=[ HAS_CODE ]
    User 0: ceDataInode=3 installed=true hidden=false suspended=true enabled=0
''';
    final apps = parseDumpsysPackages(output);
    final user = apps['com.example.app']!;
    expect(user.label, '示例应用');
    expect(user.versionName, '1.2.3');
    expect(user.versionCode, 12);
    expect(user.isSystem, isFalse);
    expect(user.isFrozen, isFalse);

    final settings = apps['com.android.settings']!;
    expect(settings.isSystem, isTrue);
    expect(settings.isFrozen, isTrue);
    expect(settings.isDisabledUser, isTrue);
    expect(settings.versionName, '14');

    final paused = apps['com.example.paused']!;
    expect(paused.isSuspended, isTrue);
    expect(paused.isDisabledUser, isFalse);
    expect(paused.isFrozen, isTrue);
  });

  test('filterInstalledApps 默认排除系统应用并支持搜索', () {
    final apps = <InstalledApp>[
      const InstalledApp(
        packageName: 'com.user.chat',
        label: '聊天',
        isSystem: false,
      ),
      const InstalledApp(
        packageName: 'com.android.settings',
        label: '设置',
        isSystem: true,
      ),
      const InstalledApp(
        packageName: 'com.user.frozen',
        label: '冻结应用',
        isDisabledUser: true,
      ),
    ];
    expect(
      filterInstalledApps(
        apps,
        filter: AppListFilter.user,
      ).map((a) => a.packageName),
      ['com.user.chat', 'com.user.frozen'],
    );
    expect(
      filterInstalledApps(
        apps,
        filter: AppListFilter.system,
      ).single.packageName,
      'com.android.settings',
    );
    expect(
      filterInstalledApps(
        apps,
        filter: AppListFilter.frozen,
      ).single.packageName,
      'com.user.frozen',
    );
    expect(
      filterInstalledApps(
        apps,
        filter: AppListFilter.all,
        query: '设置',
      ).single.packageName,
      'com.android.settings',
    );
  });

  test('systemAppRisk 有核心组件时高于普通系统应用', () {
    expect(
      systemAppRisk(const [InstalledApp(packageName: 'com.example.app')]),
      SystemAppRisk.none,
    );
    expect(
      systemAppRisk(const [
        InstalledApp(packageName: 'com.android.calculator2', isSystem: true),
        InstalledApp(packageName: 'com.example.app'),
      ]),
      SystemAppRisk.system,
    );
    expect(
      systemAppRisk(const [
        InstalledApp(packageName: 'com.android.calculator2', isSystem: true),
        InstalledApp(packageName: 'com.android.systemui', isSystem: true),
      ]),
      SystemAppRisk.core,
    );
  });

  test('pickBestIconEntry 优先选择高密度启动图标', () {
    const listing = '''
Archive:  base.apk
  Length      Date    Time    Name
---------  ---------- -----   ----
     1024  1981-01-01 01:01   res/mipmap-mdpi-v4/ic_launcher.png
     4096  1981-01-01 01:01   res/mipmap-xxhdpi-v4/ic_launcher.png
     2048  1981-01-01 01:01   res/drawable-xxhdpi-v4/ic_launcher_background.png
---------                     -------
''';
    expect(pickBestIconEntry(listing), 'res/mipmap-xxhdpi-v4/ic_launcher.png');
  });

  test('ensurePmSuccess 识别成功与失败输出', () {
    ensurePmSuccess('Success\n');
    ensurePmSuccess('', allowEmpty: true);
    expect(() => ensurePmSuccess('Failure [DELETE_FAILED]'), throwsStateError);
  });

  test('formatByteSize 按单位格式化', () {
    expect(formatByteSize(512), '512 B');
    expect(formatByteSize(2048), '2.0 KB');
    expect(formatByteSize(2 * 1024 * 1024), '2.0 MB');
  });
}
