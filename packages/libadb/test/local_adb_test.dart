import 'package:libadb/libadb.dart';
import 'package:test/test.dart';

void main() {
  test('空闲端口启动 Server，测试里不挂 USB', () async {
    final local = await LocalAdb.tryStart(
      port: 0,
      scanEmulators: false,
      usb: false,
    );
    expect(local, isNotNull);
    expect(local!.usbTracker, isNull);
    expect(local.server.isRunning, isTrue);

    final occupied = await LocalAdb.tryStart(
      port: local.server.port!,
      scanEmulators: false,
      usb: false,
    );
    expect(occupied, isNull);

    await local.close();
    expect(local.server.isRunning, isFalse);
  });
}
