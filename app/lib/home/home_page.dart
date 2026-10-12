import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';

import '../app_feedback.dart';
import '../connection/model/device_profile.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../settings/app_settings_store.dart';
import '../widgets/adaptive.dart';
import 'adb_qr_pairing.dart';
import 'adb_qr_pairing_dialog.dart';
import 'home_controller.dart';

/// 连接中心：设备列表 / 手动连接 / mDNS 设备发现 / 历史连接。
class HomePage extends GetView<HomeController> {
  const HomePage({super.key});

  Future<void> _connect(BuildContext context, String host, int port) async {
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

  Future<void> _pair(BuildContext context, MdnsService service) async {
    final code = await showDialog<String>(
      context: context,
      builder: (context) => const _PairingCodeDialog(),
    );
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
      logAppError(
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

  Future<void> _pairWithQr(BuildContext context) async {
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
        Get.toNamed<void>('/workspace', arguments: outcome.serial);
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
        actions: <Widget>[
          IconButton(
            tooltip: context.l10n.settingsTitle,
            onPressed: () => Get.toNamed<void>('/settings'),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
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

  Future<void> _setAutoRefresh(
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
      logAppError('保存自动刷新设置失败', error, stackTrace);
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

  Widget _autoRefreshControl(
    BuildContext context, {
    required Key checkboxKey,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Checkbox(
          key: checkboxKey,
          value: value,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
        ),
        GestureDetector(
          onTap: () => onChanged(!value),
          child: Text(context.l10n.homeAutoRefresh),
        ),
      ],
    );
  }

  /// 标题和右侧操作放在一行；窄宽度时操作换到下一行，避免把标题挤出屏幕。
  Widget _sectionWithActions({
    required Widget header,
    required List<Widget> actions,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final actionWrap = Wrap(
          spacing: 4,
          runSpacing: 4,
          alignment: WrapAlignment.end,
          children: actions,
        );
        if (!constraints.maxWidth.isFinite || constraints.maxWidth < 480) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              header,
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: actionWrap,
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: header),
            const SizedBox(width: 8),
            Flexible(
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: actionWrap,
              ),
            ),
          ],
        );
      },
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
            _sectionWithActions(
              header: _sectionHeader(
                context,
                Icons.radar,
                l10n.homeDeviceDiscovery,
              ),
              actions: <Widget>[
                _autoRefreshControl(
                  context,
                  checkboxKey: const ValueKey<String>('home-auto-refresh-mdns'),
                  value: Get.find<AppSettingsStore>().autoRefreshMdns.value,
                  onChanged: (value) =>
                      _setAutoRefresh(context, mdns: true, value: value),
                ),
                FilledButton.tonalIcon(
                  onPressed: controller.scanning.value
                      ? null
                      : () => controller.scan(),
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
                ),
                FilledButton.tonalIcon(
                  key: const ValueKey<String>('home-qr-pair'),
                  onPressed: controller.connecting.value
                      ? null
                      : () => _pairWithQr(context),
                  icon: const Icon(Icons.qr_code_2),
                  label: Text(l10n.homeQrPair),
                ),
              ],
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
                    // IPv6 端点（如 [fe80::…%wlan0]:5555）可能很长，限制行数
                    // 与其他 tile 的 subtitle（maxLines: 2）保持一致。
                    '${_serviceTypeLabel(context, s.serviceType)} · '
                    '${s.endpointText}',
                    maxLines: 2,
                  ),
                  trailing: s.serviceType == adbServiceTypePairing
                      ? TextButton(
                          onPressed: controller.connecting.value
                              ? null
                              : () => _pair(context, s),
                          child: Text(l10n.homePair),
                        )
                      : _serviceConnectable(s)
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
            _sectionWithActions(
              header: _sectionHeader(
                context,
                Icons.devices,
                l10n.homeDeviceCount(total),
              ),
              actions: <Widget>[
                _autoRefreshControl(
                  context,
                  checkboxKey: const ValueKey<String>(
                    'home-auto-refresh-devices',
                  ),
                  value: Get.find<AppSettingsStore>().autoRefreshDevices.value,
                  onChanged: (value) =>
                      _setAutoRefresh(context, mdns: false, value: value),
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
                l10n.homeAdbServerNotRunning(
                  controller.manager.adbServerPort.value,
                ),
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
                  title: Text(h.displayName),
                  subtitle: Text(h.connectionAddress, maxLines: 2),
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

class _PairingCodeDialog extends StatefulWidget {
  const _PairingCodeDialog();

  @override
  State<_PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<_PairingCodeDialog> {
  final TextEditingController _codeController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _codeController.text);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.homePairingTitle),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.homePairingCodeHelp),
            const SizedBox(height: 12),
            TextField(
              controller: _codeController,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: l10n.homePair,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        TextButton(onPressed: _submit, child: Text(l10n.homePair)),
      ],
    );
  }
}
