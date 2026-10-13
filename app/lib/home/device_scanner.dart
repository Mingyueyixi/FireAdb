import 'package:libadb/libadb.dart';

/// adb server 或直连 USB 这一路的结果。
///
/// 没查的那一路保持 null，调用方不要把它当成空列表。
class ListedDeviceScan {
  const ListedDeviceScan({
    this.adbDevices,
    this.usbDevices,
    this.adbError,
    this.usbError,
    this.adbServerAbsent,
    this.clearAdbError = false,
    this.clearUsbError = false,
  });

  final List<AdbDeviceInfo>? adbDevices;
  final List<UsbAdbDevice>? usbDevices;
  final String? adbError;
  final String? usbError;
  final bool? adbServerAbsent;
  final bool clearAdbError;
  final bool clearUsbError;
}

/// 一轮 mDNS 采集的最终结果。
///
/// [timedOut] 表示监听时间到了、这一轮没有新应答。这不是「没有设备」。
class MdnsDiscoverResult {
  const MdnsDiscoverResult({
    this.services = const <MdnsService>[],
    this.timedOut = false,
  });

  final List<MdnsService> services;
  final bool timedOut;
}

/// 一轮设备扫描结束时的汇总。
class DeviceScanRound {
  const DeviceScanRound({
    required this.includedMdns,
    this.services = const <MdnsService>[],
    this.timedOut = false,
    this.cancelled = false,
    this.mdnsError,
    this.mdnsStackTrace,
  });

  final bool includedMdns;
  final List<MdnsService> services;
  final bool timedOut;
  final bool cancelled;
  final Object? mdnsError;
  final StackTrace? mdnsStackTrace;
}

/// 查询 adb / USB 时，一拿到结果就 [publish]，不要等其他路。
typedef ListedDeviceQuery = Future<void> Function(
  void Function(ListedDeviceScan scan) publish,
);

/// mDNS 每解析出服务就调用 [onUpdate]，返回值是这一轮结束时的汇总。
typedef MdnsDiscover = Future<MdnsDiscoverResult> Function(
  void Function(List<MdnsService> services) onUpdate, {
  bool Function()? isCancelled,
});

/// 把 adb server、直连 USB 和 mDNS 收成一轮扫描。
///
/// 三路同时开始。某一路先返回，就先走对应回调，不等另外两路。
/// mDNS 在采集窗口里解析出服务时立刻 [onMdns]，窗口结束才 [onRoundComplete]。
class DeviceScanner {
  DeviceScanner({
    required this.queryAdb,
    required this.queryUsb,
    required this.discoverMdns,
  });

  final ListedDeviceQuery queryAdb;
  final ListedDeviceQuery queryUsb;
  final MdnsDiscover discoverMdns;

  var _mdnsBusy = false;

  bool get mdnsBusy => _mdnsBusy;

  Future<void> run({
    bool includeAdb = true,
    bool includeUsb = true,
    bool includeMdns = false,
    void Function(bool mdnsStarted)? onStart,
    void Function(ListedDeviceScan scan)? onListed,
    void Function(List<MdnsService> services)? onMdns,
    void Function(DeviceScanRound round)? onRoundComplete,
    bool Function()? isCancelled,
  }) {
    final scanMdns = includeMdns && !_mdnsBusy;
    if (scanMdns) _mdnsBusy = true;
    onStart?.call(scanMdns);
    return _execute(
      includeAdb: includeAdb,
      includeUsb: includeUsb,
      scanMdns: scanMdns,
      onListed: onListed,
      onMdns: onMdns,
      onRoundComplete: onRoundComplete,
      isCancelled: isCancelled,
    ).whenComplete(() {
      if (scanMdns) _mdnsBusy = false;
    });
  }

  Future<void> _execute({
    required bool includeAdb,
    required bool includeUsb,
    required bool scanMdns,
    void Function(ListedDeviceScan scan)? onListed,
    void Function(List<MdnsService> services)? onMdns,
    void Function(DeviceScanRound round)? onRoundComplete,
    bool Function()? isCancelled,
  }) async {
    final tasks = <Future<void>>[];
    if (includeAdb) {
      tasks.add(queryAdb((scan) => onListed?.call(scan)));
    }
    if (includeUsb) {
      tasks.add(queryUsb((scan) => onListed?.call(scan)));
    }

    MdnsDiscoverResult? mdns;
    Object? mdnsError;
    StackTrace? mdnsStackTrace;
    var cancelled = false;
    if (scanMdns) {
      tasks.add(() async {
        try {
          mdns = await discoverMdns(
            (services) => onMdns?.call(services),
            isCancelled: () {
              final stop = isCancelled?.call() ?? false;
              if (stop) cancelled = true;
              return stop;
            },
          );
        } catch (error, stackTrace) {
          mdnsError = error;
          mdnsStackTrace = stackTrace;
        }
      }());
    }

    try {
      await Future.wait(tasks);
    } finally {
      onRoundComplete?.call(
        DeviceScanRound(
          includedMdns: scanMdns,
          services: mdns?.services ?? const <MdnsService>[],
          timedOut: mdns?.timedOut ?? false,
          cancelled: cancelled,
          mdnsError: mdnsError,
          mdnsStackTrace: mdnsStackTrace,
        ),
      );
    }
  }
}
