import 'package:fire_adb/shell/device_root_store.dart';
import 'package:fire_adb/shell/root_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('adb root 不改写命令', () {
    expect(const RootPlan.adb().wrap('pm uninstall pkg'), 'pm uninstall pkg');
  });

  test('su 按探测到的写法包一层', () {
    expect(
      RootPlan.su('su', SuForm.dashC).wrap('id'),
      "'su' -c 'id'",
    );
    expect(
      RootPlan.su('/system/xbin/ksu', SuForm.uid).wrap("id"),
      "'/system/xbin/ksu' 0 sh -c 'id'",
    );
    expect(
      RootPlan.su('su', SuForm.user).wrap('id'),
      "'su' root sh -c 'id'",
    );
  });

  test('adb root 回复决定是保持 root 还是退回', () {
    expect(
      classifyAdbRootReply('adbd is already running as root'),
      AdbRootAttempt.active,
    );
    expect(
      classifyAdbRootReply('adbd cannot run as root in production builds'),
      AdbRootAttempt.unavailable,
    );
    expect(
      classifyAdbRootReply('restarting adbd as root'),
      AdbRootAttempt.restarting,
    );
  });

  test('每台设备单独记住 adb root 和 su', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = DeviceRootStore();
    await store.load();
    await store.setAdbRoot('one', true);
    await store.setSuScope('one', SuScope.files, true);
    await store.setSuCommand('one', '/sbin/su');
    store.markAdbRoot('one', true);
    final restored = DeviceRootStore();
    await restored.load();
    expect(restored.of('one').adbRoot, isTrue);
    expect(restored.of('one').fileSu, isTrue);
    expect(restored.of('one').appSu, isFalse);
    expect(restored.of('one').suCommand, '/sbin/su');
    expect(restored.of('two').adbRoot, isFalse);
    expect(restored.of('two').suCommand, 'su');
    expect(restored.isAdbRootActive('one'), isFalse);
    expect(normalizeSuCommand('bad\nname'), 'su');
    expect(
      DeviceRootOptions.fromJson(<String, Object>{'useSu': true}).fileSu,
      isTrue,
    );
    expect(
      DeviceRootOptions.fromJson(<String, Object>{'useSu': true}).appSu,
      isTrue,
    );
  });

  test('只认 uid=0', () {
    expect(isRootIdentity('uid=0(root) gid=0(root)'), isTrue);
    expect(isRootIdentity('uid=0\n'), isTrue);
    expect(isRootIdentity('uid=2000(shell)'), isFalse);
    expect(isRootIdentity('uid=10(root)'), isFalse);
  });
}
