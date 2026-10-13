import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';

import '../../connection/model/device_profile.dart';
import '../../l10n/fire_adb_localizations_ext.dart';
import '../../settings/app_settings_store.dart';
import '../discovered_devices.dart';
import '../home_actions.dart';
import '../home_controller.dart';
import 'home_section.dart';

class DeviceListSection extends GetView<HomeController> {
  const DeviceListSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
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
      final wireless = connectableDiscoveredServices(
        discovered: controller.discovered,
        adbDevices: devices,
        profiles: manager.profiles,
      );
      final total =
          devices.length +
          usbDevices.length +
          additionalConnectedProfiles.length +
          wireless.length;
      final loading =
          controller.loadingAdbDevices.value ||
          controller.loadingUsbDevices.value ||
          controller.scanning.value;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              HomeSectionBar(
                inline: true,
                header: HomeSectionHeader(
                  icon: Icons.devices,
                  title: l10n.homeDeviceCount(total),
                ),
                actions: <Widget>[
                  HomeAutoRefreshToggle(
                    checkboxKey: const ValueKey<String>(
                      'home-auto-refresh-devices',
                    ),
                    value:
                        Get.find<AppSettingsStore>().autoRefreshDevices.value,
                    onChanged: (value) =>
                        setHomeAutoRefresh(context, mdns: false, value: value),
                  ),
                  IconButton(
                    tooltip: l10n.homeRefreshAdbDevices,
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: controller.refreshDeviceList,
                    icon: HomeSpinningIcon(
                      icon: Icons.refresh,
                      spinning: loading,
                    ),
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
              for (final device in usbDevices) _UsbDeviceTile(device: device),
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
              else if (total == 0)
                Visibility(
                  visible: !loading,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: Text(
                    l10n.homeNoAdbDevices,
                    style: TextStyle(color: theme.colorScheme.outline),
                  ),
                )
              else
                for (final device in devices) _AdbDeviceTile(device: device),
              for (final profile in additionalConnectedProfiles)
                HomeListTile(
                  dense: true,
                  leading: const Icon(Icons.phone_android),
                  title: Text(profile.displayName),
                  subtitle: Text(
                    '${profile.serial} · ${l10n.homeFireAdbConnected}',
                  ),
                  trailing: IconButton(
                    tooltip: l10n.commonDisconnect,
                    icon: const Icon(Icons.link_off),
                    onPressed: () =>
                        disconnectDevice(context, controller, profile.serial),
                  ),
                  onTap: () => openWorkspace(profile.serial),
                ),
              for (final service in wireless)
                _DiscoveredDeviceTile(service: service),
            ],
          ),
        ),
      );
    });
  }
}

class _UsbDeviceTile extends GetView<HomeController> {
  const _UsbDeviceTile({required this.device});

  final UsbAdbDevice device;

  @override
  Widget build(BuildContext context) {
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
    final connecting = controller.connecting.value;
    return HomeListTile(
      dense: true,
      leading: const Icon(Icons.usb),
      title: Text(device.title),
      subtitle: Text(subtitle.toString(), maxLines: 2),
      trailing: active != null
          ? IconButton(
              tooltip: l10n.commonDisconnect,
              icon: const Icon(Icons.link_off),
              onPressed: () =>
                  disconnectDevice(context, controller, active.serial),
            )
          : TextButton(
              onPressed: connecting
                  ? null
                  : () => connectUsbDevice(context, controller, device),
              child: Text(
                connecting ? l10n.homeConnecting : l10n.commonConnect,
              ),
            ),
      onTap: active != null
          ? () => openWorkspace(active.serial)
          : connecting
          ? null
          : () => connectUsbDevice(context, controller, device),
    );
  }
}

class _DiscoveredDeviceTile extends GetView<HomeController> {
  const _DiscoveredDeviceTile({required this.service});

  final MdnsService service;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connecting = controller.connecting.value;
    final type = service.serviceType == adbServiceTypeTransport
        ? l10n.homeServiceAdbTransport
        : l10n.homeServiceTlsConnection;
    return HomeListTile(
      dense: true,
      leading: const Icon(Icons.router),
      title: Text(discoveredServiceTitle(service)),
      subtitle: Text('$type · ${service.endpointText}', maxLines: 2),
      trailing: TextButton(
        onPressed: connecting
            ? null
            : () => connectToHost(
                context,
                controller,
                service.addressText,
                service.port,
              ),
        child: Text(connecting ? l10n.homeConnecting : l10n.commonConnect),
      ),
      onTap: connecting
          ? null
          : () => connectToHost(
              context,
              controller,
              service.addressText,
              service.port,
            ),
    );
  }
}

class _AdbDeviceTile extends GetView<HomeController> {
  const _AdbDeviceTile({required this.device});

  final AdbDeviceInfo device;

  @override
  Widget build(BuildContext context) {
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
    final connecting = controller.connecting.value;
    final canConnect =
        device.isOnline && controller.manager.canConnectAdbDevice(device);

    return HomeListTile(
      dense: true,
      leading: Icon(device.devPath == null ? Icons.phone_android : Icons.usb),
      title: Text(title),
      subtitle: Text(subtitle.toString(), maxLines: 2),
      trailing: connectedProfile != null
          ? IconButton(
              tooltip: l10n.commonDisconnect,
              icon: const Icon(Icons.link_off),
              onPressed: () => disconnectDevice(
                context,
                controller,
                connectedProfile.serial,
              ),
            )
          : canConnect
          ? TextButton(
              onPressed: connecting
                  ? null
                  : () => connectListedAdbDevice(context, controller, device),
              child: Text(
                connecting ? l10n.homeConnecting : l10n.commonConnect,
              ),
            )
          : null,
      onTap: connectedProfile != null
          ? () => openWorkspace(connectedProfile.serial)
          : canConnect && !connecting
          ? () => connectListedAdbDevice(context, controller, device)
          : null,
    );
  }
}

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
