import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';

import '../app_feedback.dart';
import '../connection/model/device_profile.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../widgets/adaptive.dart';
import '../widgets/locale_selector.dart';
import 'home_controller.dart';

/// 连接中心：设备列表 / 手动连接 / mDNS 设备发现 / 历史连接。
class HomePage extends GetView<HomeController> {
  const HomePage({super.key});

  Future<void> _connect(BuildContext context, String host, int port) async {
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
      Get.toNamed<void>('/workspace', arguments: device.serial);
    } catch (error, stackTrace) {
      logAppError('连接设备失败：$host:$port', error, stackTrace);
      showAppMessage(
        messenger,
        theme,
        title: l10n.homeConnectionFailed,
        message: '$error',
        isError: true,
      );
    }
  }

  Future<void> _connectManual(BuildContext context) async {
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
    await _connect(context, host, port);
  }

  Future<void> _connectUsb(BuildContext context, UsbAdbDevice device) async {
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
      Get.toNamed<void>('/workspace', arguments: connected.serial);
    } catch (error, stackTrace) {
      logAppError('连接 USB 设备失败：${device.address}', error, stackTrace);
      showAppMessage(
        messenger,
        theme,
        title: l10n.homeConnectionFailed,
        message: '$error',
        isError: true,
      );
    }
  }

  Future<void> _connectAdbDevice(
    BuildContext context,
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
      Get.toNamed<void>('/workspace', arguments: device.serial);
    } catch (error, stackTrace) {
      logAppError('连接设备失败：${info.serial}', error, stackTrace);
      showAppMessage(
        messenger,
        theme,
        title: l10n.homeConnectionFailed,
        message: '$error',
        isError: true,
      );
    }
  }

  Future<void> _connectHistory(
    BuildContext context,
    DeviceProfile profile,
  ) async {
    final l10n = context.l10n;
    final activeDevice = controller.manager.deviceOf(profile.serial);
    if (activeDevice != null) {
      _openWorkspace(activeDevice.serial);
      return;
    }

    final host = profile.host;
    final port = profile.port;
    if (host != null && port != null) {
      await _connect(context, host, port);
      return;
    }

    final usbAddress = profile.usbAddress;
    if (usbAddress != null) {
      for (final device in controller.usbDevices) {
        if (device.address == usbAddress ||
            device.serialNumber == profile.serial) {
          await _connectUsb(context, device);
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
      await _connectAdbDevice(context, info);
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

  Future<void> _disconnect(BuildContext context, String serial) async {
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
      logAppError('断开设备失败：$serial', error, stackTrace);
      showAppMessage(
        messenger,
        theme,
        title: l10n.homeDisconnectFailed,
        message: '$error',
        isError: true,
      );
    }
  }

  void _openWorkspace(String serial) {
    Get.toNamed<void>('/workspace', arguments: serial);
  }

  String _serviceTypeLabel(BuildContext context, String type) {
    final l10n = context.l10n;
    if (type == adbServiceTypeTransport) return l10n.homeServiceAdbTransport;
    if (type == adbServiceTypeConnect) return l10n.homeServiceTlsConnection;
    if (type == adbServiceTypePairing) return l10n.homeServicePairing;
    return type;
  }

  static bool _serviceConnectable(MdnsService s) =>
      s.serviceType != adbServiceTypePairing;

  String _deviceStateLabel(BuildContext context, String state) {
    final l10n = context.l10n;
    return switch (state) {
      'device' => l10n.homeDeviceOnline,
      'offline' => l10n.homeDeviceOffline,
      'unauthorized' => l10n.homeDeviceUnauthorized,
      'bootloader' => l10n.homeDeviceBootloader,
      'recovery' => l10n.homeDeviceRecovery,
      'sideload' => l10n.homeDeviceSideload,
      '' => l10n.homeDeviceUnknownState,
      _ => state,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FireAdb'),
        actions: const <Widget>[LocaleSelector()],
      ),
      body: Obx(
        () => SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: _buildSections(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSections(BuildContext context) {
    final manual = _buildManualConnect(context);
    final discovery = _buildDiscovery(context);
    final devices = _buildDevices(context);
    final history = _buildHistory(context);
    if (isWide(context)) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              children: <Widget>[manual, const SizedBox(height: 16), discovery],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              children: <Widget>[devices, const SizedBox(height: 16), history],
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        devices,
        const SizedBox(height: 16),
        manual,
        const SizedBox(height: 16),
        discovery,
        const SizedBox(height: 16),
        history,
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, IconData icon, String title) {
    final theme = Theme.of(context);
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxWidth.isFinite) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              titleText,
            ],
          );
        }
        return Row(
          children: <Widget>[
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Flexible(child: titleText),
          ],
        );
      },
    );
  }

  /// ListTile 在尾部控件宽于整行时会直接抛异常。窄宽度把操作放到标题下方。
  Widget _homeListTile({
    required Widget leading,
    required Widget title,
    Widget? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
    bool dense = false,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 行尾按钮大约几十到一百多逻辑像素。280 以下改到标题下方，
        // 常见手机宽度仍把操作留在行尾。
        final parkTrailing = trailing != null && constraints.maxWidth < 280;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: dense,
              leading: leading,
              title: title,
              subtitle: subtitle,
              trailing: parkTrailing ? null : trailing,
              onTap: onTap,
            ),
            if (parkTrailing)
              Align(alignment: AlignmentDirectional.centerEnd, child: trailing),
          ],
        );
      },
    );
  }

  Widget _buildManualConnect(BuildContext context) {
    final l10n = context.l10n;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _sectionHeader(context, Icons.link, l10n.homeManualConnection),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: controller.hostController,
                    decoration: InputDecoration(
                      labelText: l10n.homeHostAddress,
                      hintText: l10n.homeHostAddressExample,
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _connectManual(context),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: controller.portController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: l10n.homePort,
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _connectManual(context),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: controller.connecting.value
                      ? null
                      : () => _connectManual(context),
                  icon: controller.connecting.value
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: Text(
                    controller.connecting.value
                        ? l10n.homeConnecting
                        : l10n.commonConnect,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscovery(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            LayoutBuilder(
              builder: (context, constraints) {
                final scanButton = FilledButton.tonalIcon(
                  onPressed: controller.scanning.value ? null : controller.scan,
                  icon: controller.scanning.value
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: Text(
                    controller.scanning.value
                        ? l10n.homeScanning
                        : l10n.homeScan,
                  ),
                );
                final header = _sectionHeader(
                  context,
                  Icons.radar,
                  l10n.homeDeviceDiscovery,
                );
                // 英文标题加「Scanning…」大约要 380。更窄时按钮换到下一行。
                if (constraints.maxWidth < 400) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      header,
                      const SizedBox(height: 8),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: scanButton,
                      ),
                    ],
                  );
                }
                return Row(
                  children: <Widget>[
                    Expanded(child: header),
                    const SizedBox(width: 8),
                    scanButton,
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.homeWifiDebugInfo,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.homeMdnsHelp,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (controller.scanError.value != null)
              Text(
                l10n.homeScanFailed('${controller.scanError.value}'),
                style: TextStyle(color: theme.colorScheme.error),
              )
            else if (controller.discovered.isEmpty &&
                !controller.scanning.value)
              Text(
                l10n.homeNoDevicesFound,
                style: TextStyle(color: theme.colorScheme.outline),
              )
            else
              for (final s in controller.discovered)
                _homeListTile(
                  dense: true,
                  leading: Icon(
                    _serviceConnectable(s) ? Icons.router : Icons.vpn_key,
                  ),
                  title: Text(s.instanceName),
                  subtitle: Text(
                    '${_serviceTypeLabel(context, s.serviceType)} · '
                    '${s.addressText}:${s.port}',
                  ),
                  trailing: _serviceConnectable(s)
                      ? TextButton(
                          onPressed: controller.connecting.value
                              ? null
                              : () => _connect(context, s.addressText, s.port),
                          child: Text(l10n.commonConnect),
                        )
                      : null,
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildDevices(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final devices = controller.adbDevices;
    final usbDevices = controller.showDirectUsbList
        ? controller.usbDevices
        : const <UsbAdbDevice>[];
    final manager = controller.manager;
    final additionalConnectedProfiles = manager.profiles
        .where(
          (profile) =>
              !devices.any(
                (device) => manager.profileForAdbDevice(device) == profile,
              ) &&
              !usbDevices.any(
                (device) =>
                    device.address == profile.usbAddress ||
                    (device.serialNumber != null &&
                        device.serialNumber == profile.serial),
              ),
        )
        .toList();
    final total =
        devices.length + usbDevices.length + additionalConnectedProfiles.length;
    final loading =
        controller.loadingAdbDevices.value ||
        controller.loadingUsbDevices.value;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: _sectionHeader(
                    context,
                    Icons.devices,
                    l10n.homeDeviceCount(total),
                  ),
                ),
                IconButton(
                  tooltip: l10n.homeRefreshAdbDevices,
                  onPressed:
                      (!controller.adbServerSupported.value &&
                              !controller.usbSupported) ||
                          loading
                      ? null
                      : () {
                          controller.refreshAdbDevices();
                          controller.refreshUsbDevices();
                        },
                  icon: loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (controller.manager.localUsbError.value case final localUsb?)
              Text(
                l10n.homeUsbDevicesReadError(localUsb),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            if (controller.usbDevicesError.value case final usbError?)
              Text(
                l10n.homeUsbDevicesReadError(usbError),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            for (final device in usbDevices)
              _buildUsbDeviceTile(context, device),
            if (!controller.adbServerSupported.value)
              Text(
                l10n.homeAdbServerUnavailable,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              )
            else if (controller.adbServerAbsent.value)
              Text(
                l10n.homeAdbServerNotRunning,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              )
            else if (controller.adbDevicesError.value case final error?)
              Text(
                l10n.homeAdbDevicesReadError(error),
                style: TextStyle(color: theme.colorScheme.error),
              )
            else if (loading && total == 0)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (total == 0)
              Text(
                l10n.homeNoAdbDevices,
                style: TextStyle(color: theme.colorScheme.outline),
              )
            else
              for (final device in devices)
                _buildAdbDeviceTile(context, device),
            for (final profile in additionalConnectedProfiles)
              _homeListTile(
                leading: const Icon(Icons.phone_android),
                title: Text(profile.displayName),
                subtitle: Text(
                  '${profile.serial} · ${l10n.homeFireAdbConnected}',
                ),
                trailing: IconButton(
                  tooltip: l10n.commonDisconnect,
                  icon: const Icon(Icons.link_off),
                  onPressed: () => _disconnect(context, profile.serial),
                ),
                onTap: () => _openWorkspace(profile.serial),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildUsbDeviceTile(BuildContext context, UsbAdbDevice device) {
    final manager = controller.manager;
    final l10n = context.l10n;
    DeviceProfile? connectedProfile;
    for (final profile in manager.profiles) {
      final connected = manager.deviceOf(profile.serial) != null;
      final sameUsb = profile.usbAddress == device.address;
      final sameSerial =
          device.serialNumber != null &&
          (profile.serial == device.serialNumber ||
              profile.adbSerial == device.serialNumber);
      if (connected && (sameUsb || sameSerial)) {
        connectedProfile = profile;
        break;
      }
    }
    final subtitle = StringBuffer('USB · ${device.address}');
    final serial = device.serialNumber;
    if (serial != null) subtitle.write(' · $serial');
    final active = connectedProfile;
    if (active != null) {
      subtitle.write(' · ${l10n.homeFireAdbConnected}');
    }
    return _homeListTile(
      leading: const Icon(Icons.usb),
      title: Text(device.title),
      subtitle: Text(subtitle.toString(), maxLines: 2),
      trailing: active != null
          ? IconButton(
              tooltip: l10n.commonDisconnect,
              icon: const Icon(Icons.link_off),
              onPressed: () => _disconnect(context, active.serial),
            )
          : TextButton(
              onPressed: controller.connecting.value
                  ? null
                  : () => _connectUsb(context, device),
              child: Text(
                controller.connecting.value
                    ? l10n.homeConnecting
                    : l10n.commonConnect,
              ),
            ),
      onTap: active != null
          ? () => _openWorkspace(active.serial)
          : controller.connecting.value
          ? null
          : () => _connectUsb(context, device),
    );
  }

  Widget _buildAdbDeviceTile(BuildContext context, AdbDeviceInfo device) {
    final profile = controller.manager.profileForAdbDevice(device);
    final connectedProfile =
        profile != null && controller.manager.deviceOf(profile.serial) != null
        ? profile
        : null;
    final l10n = context.l10n;
    final adbState = _deviceStateLabel(context, device.state);
    final title =
        device.model?.replaceAll('_', ' ') ?? device.product ?? device.serial;
    final subtitle = StringBuffer(device.serial);
    if (device.devPath != null) subtitle.write(' · ${device.devPath}');
    subtitle.write(' · ADB $adbState');
    if (connectedProfile != null) {
      subtitle.write(' · ${l10n.homeFireAdbConnected}');
    } else if (device.isOnline &&
        !controller.manager.canConnectAdbDevice(device)) {
      subtitle.write(' · ${l10n.homeUsbConnectionUnavailable}');
    }

    return _homeListTile(
      leading: Icon(device.devPath == null ? Icons.phone_android : Icons.usb),
      title: Text(title),
      subtitle: Text(subtitle.toString(), maxLines: 2),
      trailing: connectedProfile != null
          ? IconButton(
              tooltip: l10n.commonDisconnect,
              icon: const Icon(Icons.link_off),
              onPressed: () => _disconnect(context, connectedProfile.serial),
            )
          : device.isOnline && controller.manager.canConnectAdbDevice(device)
          ? TextButton(
              onPressed: controller.connecting.value
                  ? null
                  : () => _connectAdbDevice(context, device),
              child: Text(
                controller.connecting.value
                    ? l10n.homeConnecting
                    : l10n.commonConnect,
              ),
            )
          : null,
      onTap: connectedProfile != null
          ? () => _openWorkspace(connectedProfile.serial)
          : device.isOnline &&
                controller.manager.canConnectAdbDevice(device) &&
                !controller.connecting.value
          ? () => _connectAdbDevice(context, device)
          : null,
    );
  }

  Widget _buildHistory(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final history = controller.manager.history;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _sectionHeader(context, Icons.history, l10n.homeHistoryConnections),
            const SizedBox(height: 4),
            if (history.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  l10n.homeNoHistory,
                  style: TextStyle(color: theme.colorScheme.outline),
                ),
              )
            else
              for (final h in history)
                _homeListTile(
                  dense: true,
                  leading: const Icon(Icons.smartphone),
                  title: Text(h.toHistoryKey()),
                  trailing: IconButton(
                    tooltip: l10n.homeRemoveHistory,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => controller.manager.removeFromHistory(h),
                  ),
                  onTap: () => _connectHistory(context, h),
                ),
          ],
        ),
      ),
    );
  }
}
