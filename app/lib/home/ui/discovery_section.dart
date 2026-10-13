import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';

import '../../l10n/fire_adb_localizations_ext.dart';
import '../discovered_devices.dart';
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
      final connecting = controller.connecting.value;
      final pairing = controller.discovered
          .where((service) => service.serviceType == adbServiceTypePairing)
          .toList();
      final movedToDeviceList = controller.discovered.any(
        isConnectableAdbService,
      );
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
              else ...<Widget>[
                if (movedToDeviceList)
                  Text(
                    l10n.homeDiscoveredDevicesInList,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  )
                else if (pairing.isEmpty)
                  // 扫描中列表仍为空时也留着这句。卸掉再装上会让卡片高度来回变。
                  Text(
                    l10n.homeNoDevicesFound,
                    style: TextStyle(color: theme.colorScheme.outline),
                  ),
                for (final service in pairing)
                  HomeListTile(
                    dense: true,
                    leading: const Icon(Icons.vpn_key),
                    title: Text(service.instanceName),
                    subtitle: Text(
                      // IPv6 端点（如 [fe80::…%wlan0]:5555）可能很长，限制行数
                      // 与其他 tile 的 subtitle（maxLines: 2）保持一致。
                      '${l10n.homeServicePairing} · ${service.endpointText}',
                      maxLines: 2,
                    ),
                    trailing: TextButton(
                      onPressed: connecting
                          ? null
                          : () => pairDiscoveredService(
                              context,
                              controller,
                              service,
                            ),
                      child: Text(l10n.homePair),
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    });
  }
}
