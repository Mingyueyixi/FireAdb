import 'package:fire_adb/apps/data/bean/app_freeze.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('冻结命令按所选方式生成，互不回退', () {
    expect(
      AppFreezeMethod.disableUser.freezeCommand('com.example.app'),
      "pm disable-user 'com.example.app'",
    );
    expect(
      AppFreezeMethod.suspend.freezeCommand('com.example.app'),
      "pm suspend 'com.example.app'",
    );
    expect(
      AppFreezeMethod.amFreeze.freezeCommand('com.example.app'),
      "am freeze 'com.example.app'",
    );
    expect(
      AppFreezeMethod.disableUser.unfreezeCommand('com.example.app'),
      "pm enable 'com.example.app'",
    );
    expect(
      AppFreezeMethod.suspend.unfreezeCommand('com.example.app'),
      "pm unsuspend 'com.example.app'",
    );
    expect(
      AppFreezeMethod.amFreeze.unfreezeCommand('com.example.app'),
      "am unfreeze 'com.example.app'",
    );
  });

  test('ensureFreezeCommandSuccess 接受 Success、空输出与 suspend 状态行', () {
    ensureFreezeCommandSuccess('');
    ensureFreezeCommandSuccess('Success');
    ensureFreezeCommandSuccess('Package com.foo new suspended state: true');
    expect(
      () => ensureFreezeCommandSuccess('Unknown command: freeze'),
      throwsStateError,
    );
    expect(
      () => ensureFreezeCommandSuccess('Failure [not allowed]'),
      throwsStateError,
    );
  });

  test('isCoreSystemPackage 只标记冻结后会破坏基本功能的包', () {
    expect(isCoreSystemPackage('android'), isTrue);
    expect(isCoreSystemPackage('com.android.systemui'), isTrue);
    expect(isCoreSystemPackage('com.android.settings'), isTrue);
    expect(isCoreSystemPackage('com.android.launcher3'), isTrue);
    expect(isCoreSystemPackage('com.miui.home'), isTrue);
    expect(isCoreSystemPackage('com.android.calculator2'), isFalse);
    expect(isCoreSystemPackage('com.example.app'), isFalse);
  });

  test('parseAmFrozenPackages 从 freezer dumpsys 提取包名', () {
    const output = '''
Frozen apps:
  com.example.one
  com.example.two frozen=true
Unfrozen: com.example.skip
''';
    expect(parseAmFrozenPackages(output), {
      'com.example.one',
      'com.example.two',
    });
  });
}
