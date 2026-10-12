import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';

import '../app_feedback.dart';
import '../connection/model/device_profile.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../log/app_log.dart';
import '../settings/app_settings_store.dart';
import 'adb_qr_pairing.dart';
import 'adb_qr_pairing_dialog.dart';
import 'home_controller.dart';
import 'ui/pairing_code_dialog.dart';

Future<void> connectToHost(
  BuildContext context,
  HomeController controller,
  String host,
  int port,
) async {
  // 防重入：键盘提交 / 历史记录等入口在连接进行中直接忽略。
  if (controller.connecting.value) return;
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  try {
    final device = await controller.connect(host, port);
    showAppMessage(
      messenger,
      theme,
      title: l10n.homeConnectionSucceeded,
      message: l10n.homeConnectedDevice(device.serial),
    );
    openWorkspace(device.serial);
  } catch (error, stackTrace) {
    log.severe('连接设备失败：$host:$port', error, stackTrace);
    showAppMessage(
      messenger,
      theme,
      title: l10n.homeConnectionFailed,
      message: '$error',
      isError: true,
    );
  }
}

Future<void> connectManualInput(
  BuildContext context,
  HomeController controller,
) async {
  final l10n = context.l10n;
  final host = controller.hostController.text.trim();
  final port = int.tryParse(controller.portController.text.trim());
  if (host.isEmpty || port == null || port <= 0 || port > 65535) {
    showAppMessage(
      ScaffoldMessenger.of(context),
      Theme.of(context),
      isError: true,
      title: l10n.homeInvalidInput,
      message: l10n.homeInvalidHostPort,
    );
    return;
  }
  await connectToHost(context, controller, host, port);
}

Future<void> connectUsbDevice(
  BuildContext context,
  HomeController controller,
  UsbAdbDevice device,
) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  try {
    final connected = await controller.connectUsb(device);
    showAppMessage(
      messenger,
      theme,
      title: l10n.homeConnectionSucceeded,
      message: l10n.homeConnectedDevice(connected.serial),
    );
    openWorkspace(connected.serial);
  } catch (error, stackTrace) {
    log.severe('连接 USB 设备失败：${device.address}', error, stackTrace);
    showAppMessage(
      messenger,
      theme,
      title: l10n.homeConnectionFailed,
      message: '$error',
      isError: true,
    );
  }
}

Future<void> connectListedAdbDevice(
  BuildContext context,
  HomeController controller,
  AdbDeviceInfo info,
) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  try {
    final device = await controller.connectAdbDevice(info);
    showAppMessage(
      messenger,
      theme,
      title: l10n.homeConnectionSucceeded,
      message: l10n.homeConnectedDevice(device.serial),
    );
    openWorkspace(device.serial);
  } catch (error, stackTrace) {
    log.severe('连接设备失败：${info.serial}', error, stackTrace);
    showAppMessage(
      messenger,
      theme,
      title: l10n.homeConnectionFailed,
      message: '$error',
      isError: true,
    );
  }
}

Future<void> connectHistoryProfile(
  BuildContext context,
  HomeController controller,
  DeviceProfile profile,
) async {
  final l10n = context.l10n;
  final activeDevice = controller.manager.deviceOf(profile.serial);
  if (activeDevice != null) {
    openWorkspace(activeDevice.serial);
    return;
  }

  final host = profile.host;
  final port = profile.port;
  if (host != null && port != null) {
    await connectToHost(context, controller, host, port);
    return;
  }

  final usbAddress = profile.usbAddress;
  if (usbAddress != null) {
    for (final device in controller.usbDevices) {
      if (device.address == usbAddress ||
          device.serialNumber == profile.serial) {
        await connectUsbDevice(context, controller, device);
        return;
      }
    }
  }

  final adbSerial = profile.adbSerial;
  if (adbSerial == null) return;
  AdbDeviceInfo? info;
  for (final device in controller.adbDevices) {
    if (device.serial == adbSerial) {
      info = device;
      break;
    }
  }
  if (info != null) {
    await connectListedAdbDevice(context, controller, info);
    return;
  }
  showAppMessage(
    ScaffoldMessenger.of(context),
    Theme.of(context),
    title: l10n.homeDeviceUnavailable,
    message: l10n.homeAdbDeviceMissing,
    isError: true,
  );
}

Future<void> disconnectDevice(
  BuildContext context,
  HomeController controller,
  String serial,
) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  try {
    await controller.manager.disconnect(serial);
    showAppMessage(
      messenger,
      theme,
      title: l10n.homeDeviceDisconnected,
      message: l10n.homeDisconnectSucceeded,
    );
  } catch (error, stackTrace) {
    log.severe('断开设备失败：$serial', error, stackTrace);
    showAppMessage(
      messenger,
      theme,
      title: l10n.homeDisconnectFailed,
      message: '$error',
      isError: true,
    );
  }
}

Future<void> pairDiscoveredService(
  BuildContext context,
  HomeController controller,
  MdnsService service,
) async {
  final code = await showPairingCodeDialog(context);
  final password = code?.trim() ?? '';
  if (password.isEmpty || !context.mounted) return;
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  try {
    await controller.pair(service.addressText, service.port, password);
    if (!context.mounted) return;
    showAppMessage(
      messenger,
      theme,
      title: l10n.homePairingSucceeded,
      message: l10n.homePairingSucceededHint,
    );
  } catch (error, stackTrace) {
    log.severe(
      '无线配对失败：${service.addressText}:${service.port}',
      error,
      stackTrace,
    );
    if (!context.mounted) return;
    showAppMessage(
      messenger,
      theme,
      title: l10n.homeConnectionFailed,
      message: '$error',
      isError: true,
    );
  }
}

Future<void> pairFromQr(BuildContext context, HomeController controller) async {
  if (controller.connecting.value) return;
  final outcome = await showQrPairingDialog(context, controller);
  if (!context.mounted || outcome == null) return;
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  switch (outcome.kind) {
    case QrPairingOutcomeKind.connected:
      showAppMessage(
        messenger,
        theme,
        title: l10n.homeConnectionSucceeded,
        message: l10n.homeConnectedDevice(outcome.serial!),
      );
      openWorkspace(outcome.serial!);
    case QrPairingOutcomeKind.pairedOnly:
      showAppMessage(
        messenger,
        theme,
        title: l10n.homePairingSucceeded,
        message: l10n.homePairingSucceededHint,
      );
    case QrPairingOutcomeKind.timedOut:
    case QrPairingOutcomeKind.cancelled:
      break;
  }
}

void openWorkspace(String serial) {
  Get.toNamed<void>('/workspace', arguments: serial);
}

Future<void> setHomeAutoRefresh(
  BuildContext context, {
  required bool mdns,
  required bool value,
}) async {
  final store = Get.find<AppSettingsStore>();
  try {
    if (mdns) {
      await store.setAutoRefreshMdns(value);
    } else {
      await store.setAutoRefreshDevices(value);
    }
  } catch (error, stackTrace) {
    log.severe('保存自动刷新设置失败', error, stackTrace);
    if (!context.mounted) return;
    final l10n = context.l10n;
    showAppMessage(
      ScaffoldMessenger.of(context),
      Theme.of(context),
      title: l10n.commonSettingsSaveFailed,
      message: '$error',
      isError: true,
    );
  }
}
