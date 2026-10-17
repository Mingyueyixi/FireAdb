import 'dart:convert';
import 'dart:typed_data';

import 'package:fire_adb/apps/data/bean/installed_app.dart';
import 'package:fire_adb/apps/data/source/fire_app_service.dart';
import 'package:fire_adb/apps/loader/app_display_loader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fireAppServiceCommand 带上 classpath 和入口类', () {
    expect(
      fireAppServiceCommand('/data/local/tmp/fire-app-service.jar'),
      'CLASSPATH=/data/local/tmp/fire-app-service.jar '
      'app_process -Djava.class.path=/data/local/tmp/fire-app-service.jar '
      '/system/bin com.fire.adb.appservice.FireAppService',
    );
    expect(
      fireAppServiceCommand(
        '/data/local/tmp/fire-app-service.jar',
        argument: 'LIST',
      ),
      'CLASSPATH=/data/local/tmp/fire-app-service.jar '
      'app_process -Djava.class.path=/data/local/tmp/fire-app-service.jar '
      '/system/bin com.fire.adb.appservice.FireAppService LIST',
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
    expect(
      FireAppFrameReader().add(_header(fireAppFrameCatalogDone)).single,
      isA<FireAppCatalogDone>(),
    );
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
        flags: fireAppFlagSystem | fireAppFlagSuspended | fireAppFlagDebug,
        png: const <int>[9],
        dataDir: '/data/user/0/com.example.app',
        cacheDir: '/data/user/0/com.example.app/cache',
        externalDir: '/sdcard/Android/data/com.example.app',
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
    expect(shown.isDebuggable, isTrue);
    expect(shown.png, <int>[9]);
    expect(shown.dataDir, '/data/user/0/com.example.app');
    expect(shown.cacheDir, '/data/user/0/com.example.app/cache');
    expect(shown.externalDir, '/sdcard/Android/data/com.example.app');
  });

  test('LIST 帧带上名称、版本和 Debug 标记', () {
    final frames = FireAppFrameReader().add(
      _summary(
        packageName: 'com.example.app',
        label: '示例',
        versionName: '1.2.3',
        versionCode: 12,
        flags: fireAppFlagDebug,
        apkPath: '/data/app/com.example.app/base.apk',
        sizeBytes: 4096,
      ),
    );
    final summary = frames.single as FireAppSummary;
    expect(summary.label, '示例');
    expect(summary.versionName, '1.2.3');
    expect(summary.versionCode, 12);
    expect(summary.isDebuggable, isTrue);
    expect(summary.isSystem, isFalse);
    expect(summary.apkPaths, <String>['/data/app/com.example.app/base.apk']);
    expect(summary.sizeBytes, 4096);
    final app = applyAppSummary(
      const InstalledApp(packageName: 'com.example.app'),
      summary,
    );
    expect(app.displayName, '示例');
    expect(app.versionLabel, '1.2.3/12');
    expect(app.isDebuggable, isTrue);
    expect(app.primaryPath, '/data/app/com.example.app/base.apk');
    expect(app.sizeBytes, 4096);
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
  String dataDir = '',
  String cacheDir = '',
  String externalDir = '',
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
    ..add(png)
    ..add(_string(dataDir))
    ..add(_string(cacheDir))
    ..add(_string(externalDir));
  return builder.takeBytes();
}

Uint8List _summary({
  required String packageName,
  required String label,
  required String versionName,
  required int versionCode,
  required int flags,
  String apkPath = '',
  int sizeBytes = 0,
}) {
  final version = ByteData(4)..setInt32(0, versionCode);
  final size = ByteData(8)..setUint64(0, sizeBytes);
  final builder = BytesBuilder()
    ..add(_header(fireAppFrameApp))
    ..add(_string(packageName))
    ..add(_string(label))
    ..add(_string(versionName))
    ..add(version.buffer.asUint8List())
    ..add(<int>[flags])
    ..add(_string(apkPath))
    ..add(size.buffer.asUint8List());
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
