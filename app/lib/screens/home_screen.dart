import 'package:adb_core/adb_core.dart';
import 'package:flutter/material.dart';

import '../services/connection_manager.dart';
import '../widgets/adaptive.dart';
import 'workspace_screen.dart';

/// 连接中心：手动连接 / mDNS 设备发现 / 已连接设备 / 历史连接。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.manager});

  final ConnectionManager manager;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController =
      TextEditingController(text: '5555');
  bool _connecting = false;
  bool _scanning = false;
  List<MdnsService> _discovered = const <MdnsService>[];
  String? _scanError;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _connect(String host, int port) async {
    setState(() => _connecting = true);
    try {
      final device = await widget.manager.connectHost(host, port);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已连接：${device.serial}')),
      );
      _openWorkspace(device.serial);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('连接失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _connectManual() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效的主机地址与端口（1-65535）')),
      );
      return;
    }
    await _connect(host, port);
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanError = null;
    });
    try {
      final services = await discoverAdbServices(
        serviceTypes: const <String>{
          adbServiceTypeTransport,
          adbServiceTypeConnect,
          adbServiceTypePairing,
        },
      );
      if (!mounted) return;
      setState(() => _discovered = services);
    } catch (e) {
      if (!mounted) return;
      setState(() => _scanError = '$e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _openWorkspace(String serial) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            WorkspaceScreen(serial: serial, manager: widget.manager),
      ),
    );
  }

  Future<void> _disconnect(String serial) async {
    await widget.manager.disconnect(serial);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已断开连接')),
    );
  }

  String _serviceTypeLabel(String type) {
    if (type == adbServiceTypeTransport) return 'ADB 传输';
    if (type == adbServiceTypeConnect) return 'TLS 连接';
    if (type == adbServiceTypePairing) return '配对服务';
    return type;
  }

  static bool _serviceConnectable(MdnsService s) =>
      s.serviceType != adbServiceTypePairing;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FireAdb')),
      body: ListenableBuilder(
        listenable: widget.manager,
        builder: (context, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: _buildSections(context),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSections(BuildContext context) {
    final manual = _buildManualConnect();
    final discovery = _buildDiscovery();
    final connected = _buildConnectedDevices();
    final history = _buildHistory();
    if (isWide(context)) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              children: <Widget>[
                manual,
                const SizedBox(height: 16),
                discovery,
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              children: <Widget>[
                connected,
                const SizedBox(height: 16),
                history,
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        connected,
        const SizedBox(height: 16),
        manual,
        const SizedBox(height: 16),
        discovery,
        const SizedBox(height: 16),
        history,
      ],
    );
  }

  Widget _sectionHeader(IconData icon, String title) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }

  Widget _buildManualConnect() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _sectionHeader(Icons.link, '手动连接'),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _hostController,
                    decoration: const InputDecoration(
                      labelText: '主机地址',
                      hintText: '例如 192.168.1.100',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _connectManual(),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '端口',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _connectManual(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _connecting ? null : _connectManual,
                  icon: _connecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: Text(_connecting ? '连接中…' : '连接'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscovery() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                _sectionHeader(Icons.radar, '设备发现（mDNS）'),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: _scanning ? null : _scan,
                  icon: _scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: Text(_scanning ? '扫描中…' : '扫描'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_scanError != null)
              Text(
                '扫描失败：$_scanError',
                style: TextStyle(color: theme.colorScheme.error),
              )
            else if (_discovered.isEmpty && !_scanning)
              Text(
                '未扫描到设备。请确保设备已开启无线调试并处于同一局域网。',
                style: TextStyle(color: theme.colorScheme.outline),
              )
            else
              for (final s in _discovered)
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
                          onPressed:
                              _connecting ? null : () => _connect(s.addressText, s.port),
                          child: const Text('连接'),
                        )
                      : null,
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectedDevices() {
    final theme = Theme.of(context);
    final devices = widget.manager.profiles;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _sectionHeader(Icons.devices, '已连接设备（${devices.length}）'),
            const SizedBox(height: 4),
            if (devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '暂无已连接设备',
                  style: TextStyle(color: theme.colorScheme.outline),
                ),
              )
            else
              for (final p in devices)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(child: Icon(Icons.phone_android)),
                  title: Text(p.shortName),
                  subtitle: Text(p.serial),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        tooltip: '断开',
                        icon: const Icon(Icons.link_off),
                        onPressed: () => _disconnect(p.serial),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () => _openWorkspace(p.serial),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistory() {
    final theme = Theme.of(context);
    final history = widget.manager.history;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _sectionHeader(Icons.history, '历史连接'),
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
                    onPressed: () => widget.manager.removeFromHistory(h),
                  ),
                  onTap: () {
                    final host = h.host;
                    final port = h.port;
                    if (host != null && port != null) _connect(host, port);
                  },
                ),
          ],
        ),
      ),
    );
  }
}