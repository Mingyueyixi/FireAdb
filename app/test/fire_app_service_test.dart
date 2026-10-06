import 'dart:convert';
import 'dart:typed_data';

import 'package:fire_adb/apps/data/source/fire_app_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fireAppServiceCommand 带上 classpath 和入口类', () {
    expect(
      fireAppServiceCommand('/data/local/tmp/fire-app-service.jar'),
      'CLASSPATH=/data/local/tmp/fire-app-service.jar '
      'app_process -Djava.class.path=/data/local/tmp/fire-app-service.jar '
      '/system/bin com.fire.adb.appservice.FireAppService',
    );
  });

  test('分片到达时仍能解析名称和图标帧', () {
    final bytes =
        (BytesBuilder()
              ..add(_header(fireAppFrameReady))
              ..add(_label('com.example.app', '示例应用'))
              ..add(_header(fireAppFrameLabelsDone))
              ..add(_icon('com.example.app', <int>[1, 2, 3, 4])))
            .takeBytes();
    final reader = FireAppFrameReader();
    final frames = <FireAppFrame>[];
    for (final byte in bytes) {
      frames.addAll(reader.add(<int>[byte]));
    }
    expect(frames[0], isA<FireAppReady>());
    final label = frames[1] as FireAppLabel;
    expect(label.packageName, 'com.example.app');
    expect(label.label, '示例应用');
    expect(frames[2], isA<FireAppLabelsDone>());
    final icon = frames[3] as FireAppIcon;
    expect(icon.png, <int>[1, 2, 3, 4]);
  });

  test('SHOW 帧带上版本和标记', () {
    final frames = FireAppFrameReader().add(
      _show(
        packageName: 'com.example.app',
        label: '示例',
        versionName: '1.2.3',
        versionCode: 12,
        flags: fireAppFlagSystem | fireAppFlagSuspended,
        png: const <int>[9],
      ),
    );
    final shown = frames.single as FireAppShow;
    expect(shown.packageName, 'com.example.app');
    expect(shown.label, '示例');
    expect(shown.versionName, '1.2.3');
    expect(shown.versionCode, 12);
    expect(shown.isSystem, isTrue);
    expect(shown.isSuspended, isTrue);
    expect(shown.isDisabledUser, isFalse);
    expect(shown.png, <int>[9]);
  });

  test('版本号为 -1 时没有版本', () {
    final frames = FireAppFrameReader().add(
      _show(
        packageName: 'com.example.app',
        label: '',
        versionName: '',
        versionCode: -1,
        flags: 0,
        png: const <int>[],
      ),
    );
    final shown = frames.single as FireAppShow;
    expect(shown.versionCode, isNull);
    expect(shown.png, isNull);
  });

  test('图标长度为 0 时没有 png', () {
    final frames = FireAppFrameReader().add(
      _icon('com.android.settings', const <int>[]),
    );
    final icon = frames.single as FireAppIcon;
    expect(icon.packageName, 'com.android.settings');
    expect(icon.png, isNull);
  });
}

Uint8List _header(int type) => Uint8List.fromList(<int>[
  ...ascii.encode(fireAppServiceMagic),
  fireAppServiceVersion,
  type,
]);

Uint8List _label(String packageName, String label) {
  final builder = BytesBuilder()
    ..add(_header(fireAppFrameLabel))
    ..add(_string(packageName))
    ..add(_string(label));
  return builder.takeBytes();
}

Uint8List _show({
  required String packageName,
  required String label,
  required String versionName,
  required int versionCode,
  required int flags,
  required List<int> png,
}) {
  final version = ByteData(4)..setInt32(0, versionCode);
  final length = ByteData(4)..setUint32(0, png.length);
  final builder = BytesBuilder()
    ..add(_header(fireAppFrameShow))
    ..add(_string(packageName))
    ..add(_string(label))
    ..add(_string(versionName))
    ..add(version.buffer.asUint8List())
    ..add(<int>[flags])
    ..add(length.buffer.asUint8List())
    ..add(png);
  return builder.takeBytes();
}

Uint8List _icon(String packageName, List<int> png) {
  final length = ByteData(4)..setUint32(0, png.length);
  final builder = BytesBuilder()
    ..add(_header(fireAppFrameIcon))
    ..add(_string(packageName))
    ..add(length.buffer.asUint8List())
    ..add(png);
  return builder.takeBytes();
}

Uint8List _string(String value) {
  final utf = utf8.encode(value);
  final length = ByteData(2)..setUint16(0, utf.length);
  return Uint8List.fromList(<int>[...length.buffer.asUint8List(), ...utf]);
}
