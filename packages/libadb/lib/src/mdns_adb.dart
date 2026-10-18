import 'dart:async';

import 'package:adb_core/adb_core.dart';

/// mDNS 扩展。扫描无线调试服务，通过回调交给上层。
///
/// 可连接服务和配对服务都在这一份列表里。还没握手的服务不是传输，
/// 不写入 `host:devices`，也不标成 `offline`。
class MdnsAdbExtension implements AdbDeviceExtension {
  MdnsAdbExtension({
    this.onError,
    this.onServices,
    MdnsBrowser? browser,
  }) : _browser = browser ?? MdnsBrowser();

  static const Duration _interval = Duration(seconds: 8);

  final void Function(Object? error, StackTrace? stackTrace)? onError;
  final void Function(List<MdnsService> services)? onServices;
  final MdnsBrowser _browser;
  Timer? _timer;
  var _scanning = false;
  var _listening = false;

  @override
  void listen(AdbScanListener _) {
    unawaited(cancel());
    _listening = true;
    _timer = Timer.periodic(_interval, (_) {
      unawaited(scan());
    });
    unawaited(scan());
  }

  @override
  Future<void> cancel() async {
    _listening = false;
    _timer?.cancel();
    _timer = null;
    _browser.close();
  }

  /// 立刻再扫一轮。时间到但没有应答时保留上一轮，避免列表闪空。
  Future<void> scan() async {
    if (!_listening || _scanning) return;
    _scanning = true;
    try {
      final services = await _browser.discover(
        serviceTypes: const {
          adbServiceTypeConnect,
          adbServiceTypeTransport,
          adbServiceTypePairing,
        },
        isCancelled: () => !_listening,
      );
      if (!_listening) return;
      if (_browser.lastRoundExpiredEmpty) return;
      onError?.call(null, null);
      onServices?.call(services);
    } catch (error, stackTrace) {
      if (!_listening) return;
      onError?.call(error, stackTrace);
    } finally {
      _scanning = false;
    }
  }
}
