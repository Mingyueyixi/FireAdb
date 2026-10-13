import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';

import '../../l10n/fire_adb_localizations_ext.dart';
import '../../settings/app_settings_store.dart';
import '../home_actions.dart';
import '../home_controller.dart';
import 'home_section.dart';

class DiscoverySection extends GetView<HomeController> {
  const DiscoverySection({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final theme = Theme.of(context);
      final l10n = context.l10n;
      final scanning = controller.scanning.value;
      final connecting = controller.connecting.value;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              HomeSectionBar(
                header: HomeSectionHeader(
                  icon: Icons.radar,
                  title: l10n.homeDeviceDiscovery,
                ),
                actions: <Widget>[
                  HomeAutoRefreshToggle(
                    checkboxKey: const ValueKey<String>(
                      'home-auto-refresh-mdns',
                    ),
                    value: Get.find<AppSettingsStore>().autoRefreshMdns.value,
                    onChanged: (value) =>
                        setHomeAutoRefresh(context, mdns: true, value: value),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => controller.scan(),
                    icon: HomeSpinningIcon(
                      icon: scanning ? Icons.refresh : Icons.search,
                      spinning: scanning,
                    ),
                    label: Text(l10n.homeScan),
                  ),
                  FilledButton.tonalIcon(
                    key: const ValueKey<String>('home-qr-pair'),
                    onPressed: connecting
                        ? null
                        : () => pairFromQr(context, controller),
                    icon: const Icon(Icons.qr_code_2),
                    label: Text(l10n.homeQrPair),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
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
                    const SizedBox(height: 6),
                    Text(
                      l10n.homePairingCodeGuideTitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                      ),
                    ),
                    Text(
                      l10n.homeMdnsHelp,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.homeQrPairingGuideTitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                      ),
                    ),
                    Text(
                      l10n.homeQrPairingGuide,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (controller.scanError.value != null)
                Text(
                  l10n.homeScanFailed('${controller.scanError.value}'),
                  style: TextStyle(color: theme.colorScheme.error),
                )
              else if (controller.discovered.isEmpty)
                // 扫描中列表仍为空时也留着这句。卸掉再装上会让卡片高度来回变。
                Text(
                  l10n.homeNoDevicesFound,
                  style: TextStyle(color: theme.colorScheme.outline),
                )
              else
                for (final service in controller.discovered)
                  HomeListTile(
                    dense: true,
                    leading: Icon(
                      _connectable(service) ? Icons.router : Icons.vpn_key,
                    ),
                    title: Text(service.instanceName),
                    subtitle: Text(
                      // IPv6 端点（如 [fe80::…%wlan0]:5555）可能很长，限制行数
                      // 与其他 tile 的 subtitle（maxLines: 2）保持一致。
                      '${_serviceTypeLabel(context, service.serviceType)} · '
                      '${service.endpointText}',
                      maxLines: 2,
                    ),
                    trailing: service.serviceType == adbServiceTypePairing
                        ? TextButton(
                            onPressed: connecting
                                ? null
                                : () => pairDiscoveredService(
                                    context,
                                    controller,
                                    service,
                                  ),
                            child: Text(l10n.homePair),
                          )
                        : _connectable(service)
                        ? TextButton(
                            onPressed: connecting
                                ? null
                                : () => connectToHost(
                                    context,
                                    controller,
                                    service.addressText,
                                    service.port,
                                  ),
                            child: Text(l10n.commonConnect),
                          )
                        : null,
                  ),
            ],
          ),
        ),
      );
    });
  }
}

bool _connectable(MdnsService service) =>
    service.serviceType != adbServiceTypePairing;

String _serviceTypeLabel(BuildContext context, String type) {
  final l10n = context.l10n;
  if (type == adbServiceTypeTransport) return l10n.homeServiceAdbTransport;
  if (type == adbServiceTypeConnect) return l10n.homeServiceTlsConnection;
  if (type == adbServiceTypePairing) return l10n.homeServicePairing;
  return type;
}
