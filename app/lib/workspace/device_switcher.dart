import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';

import '../app_feedback.dart';
import '../connection/connection_manager.dart';
import '../connection/model/device_profile.dart';
import '../home/discovered_devices.dart';
import '../home/home_controller.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../log/app_log.dart';
import 'workspace_controller.dart';

/// 从设备工作区打开设备列表：已连接的用来切换，未连接的点一下就连接并切过去。
Future<void> showWorkspaceDeviceSwitcher(BuildContext context) {
  final home = Get.find<HomeController>();
  home.refreshListedDevices();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext context) => const _DeviceSwitcherSheet(),
  );
}

class _DeviceSwitcherSheet extends StatefulWidget {
  const _DeviceSwitcherSheet();

  @override
  State<_DeviceSwitcherSheet> createState() => _DeviceSwitcherSheetState();
}

class _DeviceSwitcherSheetState extends State<_DeviceSwitcherSheet> {
  String? _connectingId;

  Future<void> _switchTo(String serial) async {
    Navigator.pop(context);
    Get.find<WorkspaceController>().selectSerial(serial);
  }

  Future<void> _connectAdb(AdbDeviceInfo info) async {
    if (_connectingId != null) return;
    setState(() => _connectingId = info.serial);
    try {
      final device = await Get.find<HomeController>().connectAdbDevice(info);
      if (!mounted) return;
      await _switchTo(device.serial);
    } catch (error, stackTrace) {
      log.severe('连接设备失败：${info.serial}', error, stackTrace);
      if (!mounted) return;
      setState(() => _connectingId = null);
      _showFailure(error);
    }
  }

  Future<void> _connectDiscovered(MdnsService service) async {
    if (_connectingId != null) return;
    setState(() => _connectingId = service.endpointText);
    try {
      final device = await Get.find<HomeController>().connect(
        service.addressText,
        service.port,
      );
      if (!mounted) return;
      await _switchTo(device.serial);
    } catch (error, stackTrace) {
      log.severe('连接设备失败：${service.endpointText}', error, stackTrace);
      if (!mounted) return;
      setState(() => _connectingId = null);
      _showFailure(error);
    }
  }

  Future<void> _connectUsb(UsbAdbDevice device) async {
    if (_connectingId != null) return;
    setState(() => _connectingId = device.address);
    try {
      final connected = await Get.find<HomeController>().connectUsb(device);
      if (!mounted) return;
      await _switchTo(connected.serial);
    } catch (error, stackTrace) {
      log.severe('连接 USB 设备失败：${device.address}', error, stackTrace);
      if (!mounted) return;
      setState(() => _connectingId = null);
      _showFailure(error);
    }
  }

  void _showFailure(Object error) {
    final l10n = context.l10n;
    showAppMessage(
      ScaffoldMessenger.of(context),
      Theme.of(context),
      title: l10n.homeConnectionFailed,
      message: '$error',
      isError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final home = Get.find<HomeController>();
    final manager = Get.find<ConnectionManager>();
    final workspace = Get.find<WorkspaceController>();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;

    return Obx(() {
      final profiles = manager.profiles.toList();
      final availableAdb = home.adbDevices
          .where(
            (device) =>
                device.isOnline && manager.profileForAdbDevice(device) == null,
          )
          .toList();
      final availableUsb = home.showDirectUsbList
          ? home.usbDevices
                .where((device) => !_usbAlreadyConnected(manager, device))
                .toList()
          : const <UsbAdbDevice>[];
      final availableWireless = connectableDiscoveredServices(
        discovered: home.discovered,
        adbDevices: home.adbDevices,
        profiles: profiles,
      );
      final loading =
          home.loadingAdbDevices.value ||
          home.loadingUsbDevices.value ||
          home.scanning.value;
      final error = home.adbDevicesError.value;

      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              ListTile(
                title: Text(
                  l10n.workspaceDevices,
                  style: theme.textTheme.titleMedium,
                ),
                trailing: IconButton(
                  tooltip: l10n.homeRefreshAdbDevices,
                  onPressed: home.refreshDeviceList,
                  icon: loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ),
              if (profiles.isNotEmpty)
                _SectionLabel(l10n.workspaceConnectedDevices),
              for (final profile in profiles)
                ListTile(
                  leading: Icon(
                    profile.serial == workspace.selectedSerial.value
                        ? Icons.phone_android
                        : Icons.smartphone,
                  ),
                  title: Text(profile.displayName),
                  subtitle: Text(profile.connectionAddress),
                  trailing: profile.serial == workspace.selectedSerial.value
                      ? Icon(Icons.check, color: theme.colorScheme.primary)
                      : null,
                  onTap: _connectingId == null
                      ? () => _switchTo(profile.serial)
                      : null,
                ),
              _SectionLabel(l10n.workspaceAvailableDevices),
              if (error != null)
                ListTile(
                  title: Text(
                    l10n.homeAdbDevicesReadError(error),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                )
              else if (availableAdb.isEmpty &&
                  availableUsb.isEmpty &&
                  availableWireless.isEmpty)
                ListTile(
                  title: Text(
                    l10n.workspaceNoAvailableDevices,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              for (final device in availableAdb)
                ListTile(
                  leading: const Icon(Icons.smartphone_outlined),
                  title: Text(_adbName(device)),
                  subtitle: Text(device.serial),
                  trailing: _connectingId == device.serial
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  onTap: _connectingId == null
                      ? () => _connectAdb(device)
                      : null,
                ),
              for (final service in availableWireless)
                ListTile(
                  leading: const Icon(Icons.router),
                  title: Text(discoveredServiceTitle(service)),
                  subtitle: Text(service.endpointText),
                  trailing: _connectingId == service.endpointText
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  onTap: _connectingId == null
                      ? () => _connectDiscovered(service)
                      : null,
                ),
              for (final device in availableUsb)
                ListTile(
                  leading: const Icon(Icons.usb),
                  title: Text(device.productName ?? device.address),
                  subtitle: Text(device.address),
                  trailing: _connectingId == device.address
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  onTap: _connectingId == null
                      ? () => _connectUsb(device)
                      : null,
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.tune),
                title: Text(l10n.workspaceOtherConnections),
                onTap: () {
                  Navigator.pop(context);
                  Get.offAllNamed<void>('/');
                },
              ),
            ],
          ),
        ),
      );
    });
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(text, style: Theme.of(context).textTheme.labelLarge),
    );
  }
}

String _adbName(AdbDeviceInfo info) {
  final model = info.model?.replaceAll('_', ' ');
  if (model != null && model.isNotEmpty) return model;
  return info.serial;
}

bool _usbAlreadyConnected(ConnectionManager manager, UsbAdbDevice device) {
  for (final DeviceProfile profile in manager.profiles) {
    final sameUsb = profile.usbAddress == device.address;
    final serial = device.serialNumber;
    final sameSerial =
        serial != null &&
        (profile.serial == serial || profile.adbSerial == serial);
    if (sameUsb || sameSerial) return true;
  }
  return false;
}
