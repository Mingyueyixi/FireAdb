import 'dart:io';

import 'package:libadb/src/fire_usb.dart';
import 'package:test/test.dart';

void main() {
  test('vendor 里有 fire_usb 时可以加载并 close_all', () {
    final vendored = File('vendor/windows/x64/fire_usb.dll');
    final fire = FireUsb.tryLoad();
    if (!Platform.isWindows) {
      expect(fire, anyOf(isNull, isA<FireUsb>()));
      return;
    }
    expect(
      vendored.existsSync(),
      isTrue,
      reason: '先运行 packages/libadb/tool/build_fire_usb.ps1',
    );
    expect(fire, isNotNull);
    fire!.closeAll();
    expect(fire.isOpen('1-1'), isFalse);
  });
}
