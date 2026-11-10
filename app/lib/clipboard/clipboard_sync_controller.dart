import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../appservice/fire_app_service.dart';
import '../connection/connection_manager.dart';
import '../log/app_log.dart';
import '../settings/app_settings_store.dart';

/// 待确认的设备剪贴板推送。用户点「复制」才进本机剪贴板。
class ClipOffer {
  ClipOffer({
    required this.serial,
    required this.deviceLabel,
    required this.text,
    required this.time,
  });

  final String serial;
  final String deviceLabel;
  final String text;
  final DateTime time;

  String get preview {
    final compact = text.replaceAll('\n', ' ').trim();
    return compact.length <= 60 ? compact : '${compact.substring(0, 60)}…';
  }
}

/// 剪贴板同步。
///
/// 方向一：设备 → FireAdb。WATCH 默认开启，推送到达后挂到 [offers]
/// 等用户确认，不直接覆盖本机剪贴板。
/// 方向二：FireAdb → 设备。只在用户显式操作时发送（单发或群发）。
///
/// 多设备策略：不同设备的推送各自排队、互不覆盖；PC 写入设备后由
/// 回声抑制（内容指纹 + 15 秒窗口，加上设备侧跳过同内容）丢弃设备
/// WATCH 的回推，避免把自己发的内容再弹一次确认。
class ClipboardSyncController extends GetxController {
  ConnectionManager get manager => Get.find<ConnectionManager>();
  AppSettingsStore get _settings => Get.find<AppSettingsStore>();

  /// 待确认的设备剪贴板推送，新的在前。
  final RxList<ClipOffer> offers = <ClipOffer>[].obs;

  final _echo = <String, (String, DateTime)>{};

  @override
  void onInit() {
    super.onInit();
    setFireAppClipListener(_onIncoming);
  }

  @override
  void onClose() {
    setFireAppClipListener(null);
    super.onClose();
  }

  bool watchEnabled(String serial) =>
      !_settings.clipboardSyncOffDevices.contains(serial);

  /// 设备连上后开启 WATCH（开关默认开）。失败只记日志，不影响连接。
  Future<void> startWatch(String serial) async {
    if (!watchEnabled(serial)) return;
    final device = manager.deviceOf(serial);
    if (device == null) return;
    try {
      await watchFireAppClip(device, true);
      log.info('已开启设备剪贴板监听 $serial');
    } catch (error, stackTrace) {
      log.warning('开启设备剪贴板监听失败 $serial', error, stackTrace);
    }
  }

  /// 每设备开关。关闭时通知设备停掉 WATCH；重新开启且在线时立即补开。
  Future<void> setWatch(String serial, bool enabled) async {
    await _settings.setClipboardSync(serial, enabled);
    final device = manager.deviceOf(serial);
    if (device == null) return;
    if (enabled) {
      await startWatch(serial);
      return;
    }
    try {
      await watchFireAppClip(device, false);
    } catch (error, stackTrace) {
      log.warning('关闭设备剪贴板监听失败 $serial', error, stackTrace);
    }
    offers.removeWhere((offer) => offer.serial == serial);
  }

  void _onIncoming(String serial, String text) {
    if (text.isEmpty) return;
    if (!watchEnabled(serial)) return;
    final hash = _hash(text);
    final record = _echo[serial];
    if (record != null &&
        record.$1 == hash &&
        DateTime.now().difference(record.$2) < const Duration(seconds: 15)) {
      log.info('忽略设备剪贴板回推 $serial（本机刚写入的同一内容）');
      return;
    }
    offers.removeWhere((offer) => offer.serial == serial);
    offers.insert(
      0,
      ClipOffer(
        serial: serial,
        deviceLabel: _deviceLabel(serial),
        text: text,
        time: DateTime.now(),
      ),
    );
    if (offers.length > 5) {
      offers.removeRange(5, offers.length);
    }
  }

  /// 确认采纳：写入本机剪贴板。
  Future<void> accept(ClipOffer offer) async {
    await Clipboard.setData(ClipboardData(text: offer.text));
    offers.remove(offer);
  }

  void dismiss(ClipOffer offer) => offers.remove(offer);

  /// 把任意文本发给一台设备（写入设备剪贴板）。
  Future<void> sendTo(String serial, String text) async {
    final device = manager.deviceOf(serial);
    if (device == null) return;
    await setFireAppClip(device, text);
    _echo[serial] = (_hash(text), DateTime.now());
  }

  /// 群发：把给定文本发给所有已连接设备。返回（成功, 失败）数。
  Future<({int ok, int failed})> sendToAll(String text) async {
    var ok = 0;
    var failed = 0;
    for (final device in manager.devices) {
      try {
        await setFireAppClip(device, text);
        _echo[device.serial] = (_hash(text), DateTime.now());
        ok++;
      } catch (error, stackTrace) {
        failed++;
        log.warning('剪贴板发送失败 ${device.serial}', error, stackTrace);
      }
    }
    if (ok == 0 && failed == 0) {
      throw StateError('没有已连接的设备');
    }
    return (ok: ok, failed: failed);
  }

  String _deviceLabel(String serial) =>
      manager.profileOf(serial)?.displayName ?? serial;

  String _hash(String text) {
    final encoded = base64Encode(utf8.encode(text));
    return '${text.length}:${encoded.length}:${encoded.substring(0, encoded.length < 32 ? encoded.length : 32)}';
  }
}
