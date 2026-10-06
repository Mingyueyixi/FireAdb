import 'package:adb_core/adb_core.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app_feedback.dart';
import '../connection/model/device_profile.dart';
import '../widgets/adaptive.dart';
import 'home_controller.dart';

/// 连接中心：设备列表 / 手动连接 / mDNS 设备发现 / 历史连接。
class HomePage extends GetView<HomeController> {
  const HomePage({super.key});

  Future<void> _connect(BuildContext context, String host, int port) async {
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);
    try {
      final device = await controller.connect(host, port);
      showAppMessage(
        messenger,
        theme,
        title: '连接成功',
        message: '已连接：${device.serial}',
      );
      Get.toNamed<void>('/workspace', arguments: device.serial);
    } catch (error, stackTrace) {
      logAppError('连接设备失败：$host:$port', error, stackTrace);
      showAppMessage(
        messenger,
        theme,
        title: '连接失败',
        message: '$error',
        isError: true,
      );
    }
  }

  Future<void> _connectManual(BuildContext context) async {
    final host = controller.hostController.text.trim();
    final port = int.tryParse(controller.portController.text.trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        isError: true,
        title: '输入无效',
        message: '请输入有效的主机地址与端口（1-65535）',
      );
      return;
    }
    await _connect(context, host, port);
  }

  Future<void> _connectAdbDevice(
    BuildContext context,
    AdbDeviceInfo info,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);
    try {
      final device = await controller.connectAdbDevice(info);
      showAppMessage(
        messenger,
        theme,
        title: '连接成功',
        message: '已连接：${device.serial}',
      );
      Get.toNamed<void>('/workspace', arguments: device.serial);
    } catch (error, stackTrace) {
      logAppError('连接设备失败：${info.serial}', error, stackTrace);
      showAppMessage(
        messenger,
        theme,
        title: '连接失败',
        message: '$error',
        isError: true,
      );
    }
  }

  Future<void> _connectHistory(
    BuildContext context,
    DeviceProfile profile,
  ) async {
    final activeDevice = controller.manager.deviceOf(profile.serial);
    if (activeDevice != null) {
      _openWorkspace(activeDevice.serial);
      return;
    }

    final adbSerial = profile.adbSerial;
    if (adbSerial != null) {
      AdbDeviceInfo? info;
      for (final device in controller.adbDevices) {
        if (device.serial == adbSerial) {
          info = device;
          break;
        }
      }
      if (info != null && controller.manager.canConnectAdbDevice(info)) {
        await _connectAdbDevice(context, info);
        return;
      }
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: '设备不可用',
        message: '该设备当前未出现在 ADB 设备列表中，请先连接设备并刷新列表。',
        isError: true,
      );
      return;
    }

    final host = profile.host;
    final port = profile.port;
    if (host != null && port != null) {
      await _connect(context, host, port);
    }
  }

  Future<void> _disconnect(BuildContext context, String serial) async {
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);
    try {
      await controller.manager.disconnect(serial);
      showAppMessage(messenger, theme, title: '设备已断开', message: '已断开连接');
    } catch (error, stackTrace) {
      logAppError('断开设备失败：$serial', error, stackTrace);
      showAppMessage(
        messenger,
        theme,
        title: '断开失败',
        message: '$error',
        isError: true,
      );
    }
  }

  void _openWorkspace(String serial) {
    Get.toNamed<void>('/workspace', arguments: serial);
  }

  String _serviceTypeLabel(String type) {
    if (type == adbServiceTypeTransport) return 'ADB 传输';
    if (type == adbServiceTypeConnect) return 'TLS 连接';
    if (type == adbServiceTypePairing) return '配对服务';
    return type;
  }

  static bool _serviceConnectable(MdnsService s) =>
      s.serviceType != adbServiceTypePairing;

  String _deviceStateLabel(String state) {
    return switch (state) {
      'device' => '在线',
      'offline' => '离线',
      'unauthorized' => '未授权',
      'bootloader' => 'Bootloader',
      'recovery' => 'Recovery',
      'sideload' => 'Sideload',
      '' => '未知状态',
      _ => state,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FireAdb')),
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
    return Row(
      children: <Widget>[
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }

  Widget _buildManualConnect(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _sectionHeader(context, Icons.link, '手动连接'),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: controller.hostController,
                    decoration: const InputDecoration(
                      labelText: '主机地址',
                      hintText: '例如 192.168.1.100',
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
                    decoration: const InputDecoration(
                      labelText: '端口',
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
                  label: Text(controller.connecting.value ? '连接中…' : '连接'),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                _sectionHeader(context, Icons.radar, '设备发现（mDNS）'),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: controller.scanning.value ? null : controller.scan,
                  icon: controller.scanning.value
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: Text(controller.scanning.value ? '扫描中…' : '扫描'),
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
                          '仅适用于开启「无线调试」的 Android 11+ 设备',
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
                    '✅ 能发现：\n'
                    '• 设置 → 开发者选项 → 无线调试 → 已开启\n'
                    '• 手机与电脑在同一 Wi-Fi（无 AP 隔离）\n\n'
                    '❌ 无法发现：\n'
                    '• 仅开启 USB 调试、未开无线调试\n'
                    '• 通过 `adb connect IP:PORT` 手动连接的设备\n'
                    '• Android 11 以下或未实现 mDNS 广播的 ROM\n\n'
                    '💡 如扫描无结果，请使用上方「手动连接」输入 IP:端口直连',
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
                '扫描失败：${controller.scanError.value}',
                style: TextStyle(color: theme.colorScheme.error),
              )
            else if (controller.discovered.isEmpty &&
                !controller.scanning.value)
              Text(
                '未扫描到设备。请确认上述条件，或改用「手动连接」。',
                style: TextStyle(color: theme.colorScheme.outline),
              )
            else
              for (final s in controller.discovered)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    _serviceConnectable(s) ? Icons.router : Icons.vpn_key,
                  ),
                  title: Text(s.instanceName),
                  subtitle: Text(
                    '${_serviceTypeLabel(s.serviceType)} · '
                    '${s.addressText}:${s.port}',
                  ),
                  trailing: _serviceConnectable(s)
                      ? TextButton(
                          onPressed: controller.connecting.value
                              ? null
                              : () => _connect(context, s.addressText, s.port),
                          child: const Text('连接'),
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
    final devices = controller.adbDevices;
    final manager = controller.manager;
    final additionalConnectedProfiles = manager.profiles
        .where(
          (profile) => !devices.any(
            (device) => manager.profileForAdbDevice(device) == profile,
          ),
        )
        .toList();
    final total = devices.length + additionalConnectedProfiles.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: _sectionHeader(context, Icons.devices, '设备（$total）'),
                ),
                IconButton(
                  tooltip: '刷新 ADB 设备列表',
                  onPressed: controller.loadingAdbDevices.value
                      ? null
                      : controller.refreshAdbDevices,
                  icon: controller.loadingAdbDevices.value
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
            if (controller.adbDevicesError.value case final error?)
              Text(
                '无法读取 ADB 设备列表：$error',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            if (controller.loadingAdbDevices.value && devices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (total == 0)
              Text(
                'ADB Server 当前没有发现设备。',
                style: TextStyle(color: theme.colorScheme.outline),
              )
            else
              for (final device in devices)
                _buildAdbDeviceTile(context, device),
            for (final profile in additionalConnectedProfiles)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.phone_android),
                title: Text(profile.displayName),
                subtitle: Text('${profile.serial} · FireAdb 已连接'),
                trailing: IconButton(
                  tooltip: '断开',
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

  Widget _buildAdbDeviceTile(BuildContext context, AdbDeviceInfo device) {
    final theme = Theme.of(context);
    final profile = controller.manager.profileForAdbDevice(device);
    final connectedProfile =
        profile != null && controller.manager.deviceOf(profile.serial) != null
        ? profile
        : null;
    final adbState = _deviceStateLabel(device.state);
    final title =
        device.model?.replaceAll('_', ' ') ?? device.product ?? device.serial;
    final subtitle = StringBuffer(device.serial);
    if (device.devPath != null) subtitle.write(' · ${device.devPath}');
    subtitle.write(' · ADB $adbState');
    if (connectedProfile != null) subtitle.write(' · FireAdb 已连接');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(device.devPath == null ? Icons.phone_android : Icons.usb),
      title: Text(title),
      subtitle: Text(subtitle.toString(), maxLines: 2),
      trailing: connectedProfile != null
          ? IconButton(
              tooltip: '断开',
              icon: const Icon(Icons.link_off),
              onPressed: () => _disconnect(context, connectedProfile.serial),
            )
          : device.isOnline && controller.manager.canConnectAdbDevice(device)
          ? TextButton(
              onPressed: controller.connecting.value
                  ? null
                  : () => _connectAdbDevice(context, device),
              child: Text(controller.connecting.value ? '连接中…' : '连接'),
            )
          : Chip(
              label: Text(
                device.isOnline ? 'USB 连接暂不可用' : adbState,
              ),
              visualDensity: VisualDensity.compact,
              side: BorderSide.none,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
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
    final history = controller.manager.history;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _sectionHeader(context, Icons.history, '历史连接'),
            const SizedBox(height: 4),
            if (history.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '暂无历史记录',
                  style: TextStyle(color: theme.colorScheme.outline),
                ),
              )
            else
              for (final h in history)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.smartphone),
                  title: Text(h.toHistoryKey()),
                  trailing: IconButton(
                    tooltip: '移除历史',
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
