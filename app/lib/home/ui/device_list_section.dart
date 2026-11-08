import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';

import '../../connection/model/device_profile.dart';
import '../../l10n/fireadb_localizations_ext.dart';
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
      final manager = controller.manager;
      final additionalConnectedProfiles = manager.profiles
          .where(
            (profile) => !devices.any(
              (device) => manager.profileForAdbDevice(device) == profile,
            ),
          )
          .toList();
      final wireless = connectableDiscoveredServices(
        discovered: controller.discovered,
        adbDevices: devices,
        profiles: manager.profiles,
        localAddresses: controller.localAddresses,
      );
      final total =
          devices.length + additionalConnectedProfiles.length + wireless.length;
      final loading =
          controller.loadingAdbDevices.value || controller.scanning.value;
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
                Builder(
                  builder: (context) {
                    // 地址属于本机网卡（127.0.0.1 或本机接口 IP）的连接，
                    // 同样标注本机——手动连接 127.0.0.1 的设备不再"无感"，
                    // 与扫描到的本机服务行身份一致。
                    final endpoint = adbSerialEndpoint(profile.serial);
                    final isLocalDevice =
                        endpoint != null &&
                        controller.localAddresses.contains(
                          normalizeHost(endpoint.$1),
                        );
                    final lanAddress = isLocalDevice
                        ? controller.lanAddress.value
                        : null;
                    return HomeListTile(
                      dense: true,
                      leading: Icon(_profileIcon(profile)),
                      title: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              profile.displayName,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isLocalDevice) ...<Widget>[
                            const SizedBox(width: 6),
                            HomeLocalBadge(
                              label: context.l10n.homeLocalDevice,
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        '${profile.connectionAddress.isEmpty ? profile.serial : profile.connectionAddress}'
                        '${lanAddress == null ? '' : ' · ${l10n.homeLanAddress(lanAddress)}'}'
                        ' · ADB ${l10n.homeDeviceOnline}',
                      ),
                      trailing: IconButton(
                        tooltip: l10n.commonDisconnect,
                        icon: const Icon(Icons.link_off),
                        onPressed: () =>
                            disconnectDevice(context, controller, profile.serial),
                      ),
                      onTap: () => openWorkspace(profile.serial),
                    );
                  },
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

class _DiscoveredDeviceTile extends GetView<HomeController> {
  const _DiscoveredDeviceTile({required this.service});

  final MdnsService service;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connecting = controller.connecting.value;
    // 本机服务的局域网 IP 就是我们自己设备的 WiFi IP：与连接行同源
    // （实时枚举、WiFi 接口优先），不取扫描候选（可能含蜂窝地址）。
    final lanAddress = service.isLocal ? controller.lanAddress.value : null;
    final subtitle =
        '${service.endpointText} · ADB ${l10n.homeDeviceOnline}';
    return HomeListTile(
      dense: true,
      leading: const Icon(Icons.router),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: Text(
              discoveredServiceTitle(service),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (service.isLocal) ...<Widget>[
            const SizedBox(width: 6),
            HomeLocalBadge(label: l10n.homeLocalDevice),
          ],
        ],
      ),
      subtitle: Text(
        // 本机设备端点是 127.0.0.1；补一块局域网 IP 小字，帮用户把它和
        // 别处（路由器、adb devices 序列号）看到的 WiFi IP 对上号。
        lanAddress == null ? subtitle : '$subtitle · ${l10n.homeLanAddress(lanAddress)}',
        maxLines: 2,
      ),
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
    // 地址属于本机网卡（127.0.0.1 或本机接口 IP）的设备，标注本机，
    // 并从发现结果联查局域网 IP 小字（与发现行信息一致，不因连接断裂）。
    final endpoint = adbSerialEndpoint(device.serial);
    final isLocalDevice =
        endpoint != null &&
        controller.localAddresses.contains(normalizeHost(endpoint.$1));
    final lanAddress = isLocalDevice ? controller.lanAddress.value : null;
    final subtitle = StringBuffer(
      lanAddress == null
          ? '${device.serial} · ADB $adbState'
          : '${device.serial} · ${l10n.homeLanAddress(lanAddress)} · ADB $adbState',
    );
    if (connectedProfile == null &&
        device.isOnline &&
        !controller.manager.canConnectAdbDevice(device)) {
      subtitle.write(' · ${l10n.homeUsbConnectionUnavailable}');
    }
    final connecting = controller.connecting.value;
    final canConnect =
        device.isOnline && controller.manager.canConnectAdbDevice(device);

    return HomeListTile(
      dense: true,
      leading: Icon(_adbDeviceIcon(device)),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: Text(title, overflow: TextOverflow.ellipsis),
          ),
          if (isLocalDevice) ...<Widget>[
            const SizedBox(width: 6),
            HomeLocalBadge(label: l10n.homeLocalDevice),
          ],
        ],
      ),
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
                  : () => unawaited(
                      connectListedAdbDevice(
                        context,
                        Get.find<HomeController>(),
                        device,
                      ),
                    ),
              child: Text(
                connecting ? l10n.homeConnecting : l10n.commonConnect,
              ),
            )
          : null,
      onTap: connectedProfile != null
          ? () => openWorkspace(connectedProfile.serial)
          : canConnect && !connecting
          ? () => unawaited(
              connectListedAdbDevice(
                context,
                Get.find<HomeController>(),
                device,
              ),
            )
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

IconData _adbDeviceIcon(AdbDeviceInfo device) {
  if (adbSerialEndpoint(device.serial) != null) return Icons.router;
  if (device.serial.startsWith('emulator-')) return Icons.phone_android;
  return Icons.usb;
}

IconData _profileIcon(DeviceProfile profile) {
  if (profile.usbAddress != null && profile.usbAddress!.isNotEmpty) {
    return Icons.usb;
  }
  if (profile.host != null && profile.port != null) return Icons.router;
  if (profile.serial.startsWith('emulator-')) return Icons.phone_android;
  if (adbSerialEndpoint(profile.serial) != null) return Icons.router;
  return Icons.usb;
}
