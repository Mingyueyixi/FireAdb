import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../l10n/fire_adb_localizations_ext.dart';
import '../home_actions.dart';
import '../home_controller.dart';
import 'home_section.dart';

class ManualConnectSection extends GetView<HomeController> {
  const ManualConnectSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final l10n = context.l10n;
      final connecting = controller.connecting.value;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              HomeSectionHeader(
                icon: Icons.link,
                title: l10n.homeManualConnection,
              ),
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
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) =>
                          connectManualInput(context, controller),
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
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) =>
                          connectManualInput(context, controller),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: connecting
                        ? null
                        : () => connectManualInput(context, controller),
                    icon: connecting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.link),
                    label: Text(
                      connecting ? l10n.homeConnecting : l10n.commonConnect,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    });
  }
}
