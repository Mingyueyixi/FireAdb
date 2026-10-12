import 'dart:async';

import 'package:flutter/material.dart';

import 'package:libadb/libadb.dart';

import '../app_feedback.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import 'adb_qr_code.dart';
import 'adb_qr_pairing.dart';
import 'home_controller.dart';

/// 展示二维码，等手机扫描后完成配对并尽量连上 TLS 端口。
Future<QrPairingOutcome?> showQrPairingDialog(
  BuildContext context,
  HomeController controller,
) {
  return showDialog<QrPairingOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _QrPairingDialog(controller: controller),
  );
}

class _QrPairingDialog extends StatefulWidget {
  const _QrPairingDialog({required this.controller});

  final HomeController controller;

  @override
  State<_QrPairingDialog> createState() => _QrPairingDialogState();
}

class _QrPairingDialogState extends State<_QrPairingDialog> {
  late final AdbQrPairing _session;
  var _phase = QrPairingPhase.waiting;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _session = AdbQrPairing.generate();
    logAppLine('开始二维码配对，等待服务 ${_session.serviceName}');
    unawaited(_watch());
  }

  Future<List<MdnsService>> _discover({
    Duration? timeout,
    bool Function(List<MdnsService> services)? stopWhen,
    bool Function()? isCancelled,
  }) async {
    final services = await widget.controller.discoverServicesOnce(
      timeout: timeout,
      stopWhen: stopWhen,
      isCancelled: isCancelled,
      onUpdate: (found) {
        logAppLine(
          '二维码配对发现 ${found.length} 个：'
          '${found.map((service) => '${service.instanceName}\t${service.serviceType}\t${service.endpointText}').join('；')}',
        );
      },
    );
    if (services.isEmpty) {
      logAppLine('二维码配对结束，没有发现服务');
    }
    return services;
  }

  Future<void> _watch() async {
    try {
      final outcome = await watchQrPairing(
        session: _session,
        discover: _discover,
        pair: widget.controller.pair,
        connect: (host, port) async {
          final device = await widget.controller.connect(host, port);
          return device.serial;
        },
        isCancelled: () => !mounted,
        onPhase: (phase) {
          logAppLine(switch (phase) {
            QrPairingPhase.waiting => '二维码配对仍在等待手机扫描',
            QrPairingPhase.pairing => '已匹配 ${_session.serviceName}，开始无线配对',
            QrPairingPhase.connecting => '无线配对完成，开始连接',
          });
          if (!mounted) return;
          setState(() => _phase = phase);
        },
      );
      if (!mounted) return;
      switch (outcome.kind) {
        case QrPairingOutcomeKind.connected:
        case QrPairingOutcomeKind.pairedOnly:
          Navigator.pop(context, outcome);
        case QrPairingOutcomeKind.timedOut:
          setState(() => _failure = context.l10n.homeQrPairingTimeout);
        case QrPairingOutcomeKind.cancelled:
          break;
      }
    } catch (error, stackTrace) {
      logAppError('二维码配对失败', error, stackTrace);
      if (!mounted) return;
      setState(() => _failure = context.l10n.homeQrPairingFailed('$error'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = switch (_phase) {
      QrPairingPhase.waiting => l10n.homeQrPairingWaiting,
      QrPairingPhase.pairing => l10n.homeQrPairingPairing,
      QrPairingPhase.connecting => l10n.homeQrPairingConnecting,
    };
    return AlertDialog(
      title: Text(l10n.homeQrPairingTitle),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(l10n.homeQrPairingPrinciple),
              const SizedBox(height: 8),
              Text(
                l10n.homeQrPairingHelp,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              ColoredBox(
                color: const Color(0xFFFFFFFF),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: AdbQrCodeView(
                    key: const ValueKey<String>('home-qr-pairing-code'),
                    data: _session.payload,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_failure == null)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Flexible(child: Text(status)),
                  ],
                )
              else
                Text(
                  _failure!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_failure == null ? l10n.commonCancel : l10n.commonClose),
        ),
      ],
    );
  }
}
