import 'package:get/get.dart';

import '../connection/connection_manager.dart';
import '../connection/model/connected_device.dart';
import '../log/app_log.dart';
import 'root_shell.dart';

enum AdbRootOutcome { enabled, keptNormal, disconnected }

class AdbRootResult {
  const AdbRootResult(this.outcome, {this.detail = ''});

  final AdbRootOutcome outcome;
  final String detail;
}

/// 连接时调用。这台设备开过 adb root，就先提权；连不上就关掉，留在普通连接。
Future<void> activateSavedAdbRoot(String serial) async {
  if (!Get.isRegistered<DeviceRootStore>()) return;
  final store = Get.find<DeviceRootStore>();
  if (!store.of(serial).adbRoot) return;
  try {
    final outcome = await activateAdbRoot(serial);
    if (outcome.outcome != AdbRootOutcome.enabled) {
      final detail = outcome.detail;
      log.info(
        detail.isEmpty
            ? '设备 $serial 的 adb root 未连上，已退回普通连接'
            : '设备 $serial 的 adb root 未连上：$detail',
      );
    }
  } catch (error, stackTrace) {
    log.severe('adb root 连接失败，退回普通连接：$serial', error, stackTrace);
    store.markAdbRoot(serial, false);
    await store.setAdbRoot(serial, false);
  }
}

Future<AdbRootResult> activateAdbRoot(String serial) async {
  final manager = Get.find<ConnectionManager>();
  final store = Get.find<DeviceRootStore>();
  final device = manager.deviceOf(serial);
  if (device == null) return const AdbRootResult(AdbRootOutcome.disconnected);
  final status = await requestAdbRoot(device);
  if (status.attempt == AdbRootAttempt.active) {
    store.markAdbRoot(serial, true);
    await store.setAdbRoot(serial, true);
    return const AdbRootResult(AdbRootOutcome.enabled);
  }
  if (status.attempt == AdbRootAttempt.restarting) {
    final restored = await _reconnectUntilReady(manager, serial);
    if (restored == null) {
      store.markAdbRoot(serial, false);
      await store.setAdbRoot(serial, false);
      return AdbRootResult(AdbRootOutcome.disconnected, detail: status.detail);
    }
    if (isRootIdentity(await runDeviceShell(restored, 'id'))) {
      store.markAdbRoot(restored.serial, true);
      await store.setAdbRoot(restored.serial, true);
      return const AdbRootResult(AdbRootOutcome.enabled);
    }
    store.markAdbRoot(restored.serial, false);
    await store.setAdbRoot(restored.serial, false);
    return AdbRootResult(AdbRootOutcome.keptNormal, detail: status.detail);
  }
  store.markAdbRoot(serial, false);
  await store.setAdbRoot(serial, false);
  return AdbRootResult(AdbRootOutcome.keptNormal, detail: status.detail);
}

Future<String> deactivateAdbRoot(String serial) async {
  final manager = Get.find<ConnectionManager>();
  final store = Get.find<DeviceRootStore>();
  store.markAdbRoot(serial, false);
  await store.setAdbRoot(serial, false);
  final device = manager.deviceOf(serial);
  if (device == null) return '';
  final status = await requestAdbUnroot(device);
  if (status.attempt == AdbRootAttempt.restarting) {
    final restored = await _reconnectUntilReady(manager, serial);
    if (restored == null) return status.detail;
  }
  if (status.attempt == AdbRootAttempt.unavailable) return status.detail;
  return '';
}

Future<void> enableDeviceSu(
  String serial, {
  required SuScope scope,
  String? command,
}) async {
  final manager = Get.find<ConnectionManager>();
  final store = Get.find<DeviceRootStore>();
  final device = manager.deviceOf(serial);
  if (device == null) throw StateError('设备未连接');
  final binary = normalizeSuCommand(command ?? store.of(serial).suCommand);
  forgetRootPlansFor(serial);
  await suPlanFor(device, suBinary: binary);
  await store.setSuCommand(serial, binary);
  await store.setSuScope(serial, scope, true);
}

Future<void> disableDeviceSu(String serial, {required SuScope scope}) {
  return Get.find<DeviceRootStore>().setSuScope(serial, scope, false);
}

Future<void> updateDeviceSuCommand(String serial, String command) async {
  final store = Get.find<DeviceRootStore>();
  final binary = normalizeSuCommand(command);
  forgetRootPlansFor(serial);
  if (store.of(serial).usesSu) {
    final device = Get.find<ConnectionManager>().deviceOf(serial);
    if (device == null) throw StateError('设备未连接');
    await suPlanFor(device, suBinary: binary);
  }
  await store.setSuCommand(serial, binary);
}

Future<ConnectedDevice?> _reconnectUntilReady(
  ConnectionManager manager,
  String serial,
) async {
  for (var attempt = 0; attempt < 8; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    try {
      final restored = await manager.reconnectDirect(serial);
      if (restored == null) continue;
      await runDeviceShell(restored, 'id');
      return restored;
    } catch (error) {
      log.info('等待设备 $serial 重新连接：$error');
    }
  }
  return null;
}
