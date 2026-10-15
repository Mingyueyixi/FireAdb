import 'dart:convert';

import 'package:get/get.dart';

import '../connection/model/connected_device.dart';
import '../log/app_log.dart';
import 'device_root_store.dart';
import 'root_plan.dart';

export 'device_root_store.dart';
export 'root_plan.dart';

enum AdbRootAttempt { active, unavailable, restarting }

class AdbRootStatus {
  const AdbRootStatus(this.attempt, [this.detail = '']);

  final AdbRootAttempt attempt;
  final String detail;
}

String rootFailureText(Object error) {
  if (error is StateError && error.message.isNotEmpty) return error.message;
  return '$error';
}

/// 这个功能打开了 su，并且当前连接不是 adb root。
bool commandUsesSu(ConnectedDevice device, SuScope scope) {
  if (!Get.isRegistered<DeviceRootStore>()) return false;
  final store = Get.find<DeviceRootStore>();
  return store.of(device.serial).suFor(scope) &&
      !store.isAdbRootActive(device.serial);
}

Future<String> rootCommand(
  ConnectedDevice device,
  String command, {
  required SuScope scope,
}) async {
  if (!commandUsesSu(device, scope)) return command;
  final binary = Get.find<DeviceRootStore>().of(device.serial).suCommand;
  final plan = await suPlanFor(device, suBinary: binary);
  return plan.wrap(command);
}

AdbRootAttempt classifyAdbRootReply(String message) {
  if (message.contains('already running as root')) return AdbRootAttempt.active;
  if (message.contains('cannot run as root')) return AdbRootAttempt.unavailable;
  if (message.contains('restarting')) return AdbRootAttempt.restarting;
  return AdbRootAttempt.unavailable;
}

/// 让这条连接变成 root。正式版系统返回 [AdbRootAttempt.unavailable]，连接还在。
/// 直连设备重启 adbd 时返回 [AdbRootAttempt.restarting]，调用方再重连。
Future<AdbRootStatus> requestAdbRoot(ConnectedDevice device) async {
  try {
    if (isRootIdentity(await runDeviceShell(device, 'id'))) {
      return const AdbRootStatus(AdbRootAttempt.active);
    }
  } catch (error, stackTrace) {
    log.info('读取 adb 身份失败', error, stackTrace);
  }
  final String message;
  try {
    message = (await device.serviceText('root:')).trim();
  } catch (error, stackTrace) {
    log.info('adb root 不可用', error, stackTrace);
    return AdbRootStatus(AdbRootAttempt.unavailable, rootFailureText(error));
  }
  log.info('adb root：$message');
  final attempt = classifyAdbRootReply(message);
  if (attempt != AdbRootAttempt.restarting || !device.usesHost) {
    return AdbRootStatus(attempt, message);
  }
  final rooted = await _waitUntil(
    device,
    (output) => isRootIdentity(output),
  );
  return AdbRootStatus(
    rooted ? AdbRootAttempt.active : AdbRootAttempt.unavailable,
    message,
  );
}

/// 关掉 adb root。直连重启时 [AdbRootStatus.attempt] 为 [AdbRootAttempt.restarting]。
Future<AdbRootStatus> requestAdbUnroot(ConnectedDevice device) async {
  try {
    if (!isRootIdentity(await runDeviceShell(device, 'id'))) {
      return const AdbRootStatus(AdbRootAttempt.active);
    }
  } catch (error, stackTrace) {
    log.info('读取 adb 身份失败', error, stackTrace);
  }
  final String message;
  try {
    message = (await device.serviceText('unroot:')).trim();
  } catch (error, stackTrace) {
    log.info('adb unroot 不可用', error, stackTrace);
    return AdbRootStatus(AdbRootAttempt.unavailable, rootFailureText(error));
  }
  log.info('adb unroot：$message');
  if (message.contains('not running as root')) {
    return AdbRootStatus(AdbRootAttempt.active, message);
  }
  if (!message.contains('restarting')) {
    return AdbRootStatus(AdbRootAttempt.unavailable, message);
  }
  if (!device.usesHost) {
    return AdbRootStatus(AdbRootAttempt.restarting, message);
  }
  final normal = await _waitUntil(
    device,
    (output) => !isRootIdentity(output) && output.contains('uid='),
  );
  return AdbRootStatus(
    normal ? AdbRootAttempt.active : AdbRootAttempt.unavailable,
    message,
  );
}

Future<RootPlan> suPlanFor(
  ConnectedDevice device, {
  required String suBinary,
}) async {
  final binary = suBinary.trim();
  if (binary.isEmpty || binary.contains('\n') || binary.contains('\r')) {
    throw StateError('su 命令无效');
  }
  final key = '${device.serial}\n$binary';
  final cached = cachedRootPlan(key);
  if (cached != null && !cached.adbRoot) return cached;
  final plan = await _probeSu(device, binary);
  rememberRootPlan(key, plan);
  log.info('使用 $binary ${plan.form.name} 执行 su');
  return plan;
}

Future<bool> _waitUntil(
  ConnectedDevice device,
  bool Function(String output) matches,
) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    try {
      final output = await runDeviceShell(device, 'id');
      if (matches(output)) return true;
    } catch (_) {}
  }
  return false;
}

Future<RootPlan> _probeSu(ConnectedDevice device, String binary) async {
  final probes = <(SuForm, String)>[
    (SuForm.dashC, RootPlan.su(binary, SuForm.dashC).wrap('id')),
    (SuForm.uid, RootPlan.su(binary, SuForm.uid).wrap('id')),
    (SuForm.user, RootPlan.su(binary, SuForm.user).wrap('id')),
  ];
  final failures = <String>[];
  for (final (form, command) in probes) {
    try {
      final output = await runDeviceShell(
        device,
        command,
        timeout: const Duration(seconds: 5),
      );
      if (isRootIdentity(output)) return RootPlan.su(binary, form);
      final text = output.trim();
      failures.add(text.isEmpty ? '$command 没有输出' : text);
    } catch (error, stackTrace) {
      log.info('$binary ${form.name} 未取得 root', error, stackTrace);
      failures.add(rootFailureText(error));
    }
  }
  throw StateError(failures.join('\n'));
}

Future<String> runDeviceShell(
  ConnectedDevice device,
  String command, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final shell = await device.openShell(command);
  try {
    final bytes = await shell.readStream
        .expand((chunk) => chunk)
        .toList()
        .timeout(timeout);
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    await shell.close();
  }
}
