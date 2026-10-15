import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app_feedback.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../log/app_log.dart';
import 'device_root.dart';
import 'device_root_store.dart';

/// 文件管理或应用管理自己的 su 开关。
class SuModeChip extends StatefulWidget {
  const SuModeChip({
    super.key,
    required this.serial,
    required this.scope,
    this.inline = false,
  });

  final String serial;
  final SuScope scope;

  /// 和旁边的操作排在同一行，不再单独占一行。
  final bool inline;

  @override
  State<SuModeChip> createState() => _SuModeChipState();
}

class _SuModeChipState extends State<SuModeChip> {
  var _busy = false;

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<DeviceRootStore>()) return const SizedBox.shrink();
    final l10n = context.l10n;
    final help = switch (widget.scope) {
      SuScope.files => l10n.filesSuModeHelp,
      SuScope.apps => l10n.appsSuModeHelp,
    };
    final store = Get.find<DeviceRootStore>();
    final theme = Theme.of(context);
    return Obx(() {
      final selected = store.of(widget.serial).suFor(widget.scope);
      if (widget.inline) {
        return _InlineSuButton(
          label: l10n.suMode,
          selected: selected,
          enabled: !_busy,
          help: help,
          onToggle: () => unawaited(_toggle(!selected)),
        );
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: <Widget>[
            Text(l10n.suMode, style: theme.textTheme.bodyLarge),
            _SuHelpButton(help: help),
            const Spacer(),
            Switch(value: selected, onChanged: _busy ? null : _toggle),
          ],
        ),
      );
    });
  }

  Future<void> _toggle(bool value) async {
    setState(() => _busy = true);
    try {
      if (!value) {
        await disableDeviceSu(widget.serial, scope: widget.scope);
        return;
      }
      await enableDeviceSu(widget.serial, scope: widget.scope);
    } catch (error, stackTrace) {
      log.severe('打开 su 失败：${widget.serial}', error, stackTrace);
      if (!mounted) return;
      final detail = switch (error) {
        StateError(:final message) when message.isNotEmpty => message,
        _ => context.l10n.deviceSuFailed,
      };
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.suMode,
        message: detail,
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _InlineSuButton extends StatelessWidget {
  const _InlineSuButton({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.help,
    required this.onToggle,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final String help;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = selected
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: selected ? colors.secondaryContainer : colors.surface,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? colors.secondaryContainer : colors.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 32,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              InkWell(
                onTap: enabled ? onToggle : null,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 8),
                  child: Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: foreground,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 1,
                height: 14,
                child: ColoredBox(
                  color: selected
                      ? colors.onSecondaryContainer.withValues(alpha: 0.24)
                      : colors.outlineVariant,
                ),
              ),
              _SuHelpButton(help: help, color: foreground, embedded: true),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuHelpButton extends StatelessWidget {
  const _SuHelpButton({
    required this.help,
    this.color,
    this.embedded = false,
  });

  final String help;
  final Color? color;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = color ?? theme.colorScheme.onSurfaceVariant;
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      style: const MenuStyle(
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      menuChildren: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Text(help, style: theme.textTheme.bodyMedium),
          ),
        ),
      ],
      builder: (context, controller, child) {
        return InkWell(
          onTap: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: embedded ? 8 : 4),
            child: Icon(
              Icons.info_outline,
              size: embedded ? 16 : 18,
              color: iconColor,
            ),
          ),
        );
      },
    );
  }
}
