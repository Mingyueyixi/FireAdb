import 'dart:io';

import 'package:fire_adb/apps/data/source/fire_app_service.dart';
import 'package:fire_adb/capture/data/capture_paths.dart';
import 'package:fire_adb/capture/data/capture_store.dart';
import 'package:fire_adb/capture/data/local_opener.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('应用目录优先使用 HOME，否则使用 USERPROFILE', () {
    expect(
      captureDirectoryPath(const <String, String>{
        'HOME': '/home/mi',
        'USERPROFILE': r'C:\Users\Mi',
      }, separator: '/'),
      '/home/mi/.config/fire_adb/captures',
    );
    expect(
      captureDirectoryPath(const <String, String>{
        'USERPROFILE': r'C:\Users\Mi',
      }, separator: r'\'),
      r'C:\Users\Mi\.config\fire_adb\captures',
    );
    expect(captureDirectoryPath(const <String, String>{}), isNull);
    expect(
      captureDirectoryPath(const <String, String>{
        'HOME': '/home/mi/',
      }, separator: '/'),
      '/home/mi/.config/fire_adb/captures',
    );
  });

  test('截图和录屏命令', () {
    expect(kScreencapCommand, 'screencap -p');
    expect(
      captureFileName(
        prefix: 'screenshot',
        time: DateTime(2026, 10, 7, 11, 19, 23),
        serial: '192.168.1.8:5555',
        extension: 'png',
      ),
      'screenshot_20261007_111923_192.168.1.8_5555.png',
    );
    expect(
      captureFileMatchesDevice(
        'screenshot_20261007_111923_192.168.1.8_5555.png',
        '192.168.1.8:5555',
      ),
      isTrue,
    );
    expect(
      captureFileMatchesDevice(
        'screenshot_20261007_111923_192.168.1.8_5555.png',
        '192.168.1.80:5555',
      ),
      isFalse,
    );
    expect(
      captureFileMatchesDevice('screenshot_20261007_111923_18.png', '8'),
      isFalse,
    );
    expect(isSafeCaptureName('screenshot_20261007_111923.png'), isTrue);
    expect(isSafeCaptureName('../a.png'), isFalse);
    expect(isSafeCaptureName(r'..\a.png'), isFalse);
    expect(
      joinRemoteCapturePath(kDeviceCaptureDir, 'screenrecord_1.mp4'),
      '/sdcard/FireAdb/screenrecord_1.mp4',
    );
    expect(
      () => joinRemoteCapturePath('/sdcard/../etc', 'a.mp4'),
      throwsArgumentError,
    );
    final probe = resolveScreenrecordDirCommand();
    expect(
      probe.indexOf("mkdir -p '/sdcard/FireAdb'"),
      lessThan(probe.indexOf("mkdir -p '/data/local/tmp'")),
    );
    expect(probe, contains("exec 3<>'/sdcard/FireAdb/fireadb_w'"));
    expect(probe, contains("exec 3<>'/data/local/tmp/fireadb_w'"));
    expect(probe, isNot(contains('touch ')));
    expect(parseWritableDir('noise\n/sdcard/FireAdb\n'), '/sdcard/FireAdb');
    expect(parseWritableDir('Permission denied'), isNull);
    final remote = joinRemoteCapturePath(
      kDeviceCaptureDir,
      'screenrecord_1.mp4',
    );
    expect(
      screenrecordCommand(remotePath: remote, timeLimitSeconds: 30),
      "screenrecord --time-limit 30 '/sdcard/FireAdb/screenrecord_1.mp4'",
    );
    expect(
      screenrecordCommand(remotePath: remote, timeLimitSeconds: 999),
      "screenrecord --time-limit 180 '/sdcard/FireAdb/screenrecord_1.mp4'",
    );
    expect(
      screenrecordCommand(
        remotePath: remote,
        timeLimitSeconds: 999,
        allowUnlimited: true,
      ),
      "screenrecord --time-limit 999 '/sdcard/FireAdb/screenrecord_1.mp4'",
    );
    expect(
      screenrecordCommand(
        remotePath: remote,
        timeLimitSeconds: 0,
        allowUnlimited: true,
      ),
      "screenrecord --time-limit 0 '/sdcard/FireAdb/screenrecord_1.mp4'",
    );
    final probed = parseRecordingDeviceProbe(
      'u:object_r:screen_record_exec:s0 /system/bin/screenrecord\n---\n36\n',
    );
    expect(probed.needsShellCopy, isTrue);
    expect(probed.sdk, 36);
    expect(screenrecordAllowsUnlimited(36), isTrue);
    expect(screenrecordAllowsUnlimited(33), isFalse);
    expect(screenrecordAllowsUnlimited(null), isFalse);
    expect(
      stopScreenrecordCommand(),
      'pids=\$(pidof screenrecord 2>/dev/null || true); '
      'if [ -n "\$pids" ]; then kill -INT \$pids; fi',
    );
    expect(stopScreenrecordCommand(), contains(r'kill -INT $pids'));
    expect(stopScreenrecordCommand().contains('\\'), isFalse);
    expect(
      systemScreenrecordContextCommand(),
      "ls -Z '/system/bin/screenrecord'",
    );
    expect(
      systemScreenrecordNeedsShellCopy(
        '-rwxr-xr-x 1 root shell u:object_r:screen_record_exec:s0 143552 /system/bin/screenrecord',
      ),
      isTrue,
    );
    expect(
      systemScreenrecordNeedsShellCopy(
        '-rwxr-xr-x 1 root shell u:object_r:system_file:s0 /system/bin/screenrecord',
      ),
      isFalse,
    );
    expect(
      installShellRecorderCommand(),
      "if [ -e '/data/local/tmp/fireadb_sr' ]; then "
      "ls -Z '/data/local/tmp/fireadb_sr'; "
      "else cp '/system/bin/screenrecord' '/data/local/tmp/fireadb_sr' && "
      "chmod 755 '/data/local/tmp/fireadb_sr' && "
      "ls -Z '/data/local/tmp/fireadb_sr'; fi",
    );
    expect(
      shellRecorderContextIsSafe(
        'u:object_r:shell_data_file:s0 /data/local/tmp/fireadb_sr',
      ),
      isTrue,
    );
    expect(
      shellRecorderContextIsSafe(
        'u:object_r:screen_record_exec:s0 /data/local/tmp/fireadb_sr',
      ),
      isFalse,
    );
    expect(
      shellRecorderCommand(
        remotePath: '/data/local/tmp/a.mp4',
        timeLimitSeconds: 30,
      ),
      "'/data/local/tmp/fireadb_sr' --time-limit 30 '/data/local/tmp/a.mp4'",
    );
    expect(kBuiltinRecorderJar, fireAppServiceRemotePath);
    expect(
      builtinRecordCommand(
        remotePath: '/data/local/tmp/a.mp4',
        timeLimitSeconds: 0,
      ),
      "rm -f '/data/local/tmp/fireadb_rec.stop' && "
      'CLASSPATH=/data/local/tmp/fire-app-service.jar '
      'app_process -Djava.class.path=/data/local/tmp/fire-app-service.jar '
      '/system/bin com.fire.adb.appservice.ScreenRecorder '
      "--output '/data/local/tmp/a.mp4' --time-limit 0",
    );
    expect(
      stopBuiltinRecordCommand(),
      "touch '/data/local/tmp/fireadb_rec.stop'",
    );
    expect(
      stopScreenrecordCommand(kShellRecorderName),
      contains('pidof fireadb_sr'),
    );
    expect(
      removeRemoteFileCommand(remote),
      "rm -f '/sdcard/FireAdb/screenrecord_1.mp4'",
    );
    expect(formatElapsed(const Duration(seconds: 75)), '01:15');
    expect(briefDeviceOutput('  hi  '), 'hi');
    expect(
      briefDeviceOutput(
        'noise\rfireadb-record try virtual\n'
        'fireadb-record skip virtual: SecurityException: denied\n',
      ),
      'fireadb-record try virtual\n'
      'fireadb-record skip virtual: SecurityException: denied',
    );
  });

  test('识别 PNG 和 MP4，并限制删除范围', () {
    expect(
      looksLikePng(const <int>[
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
        0,
      ]),
      isTrue,
    );
    expect(looksLikePng(const <int>[0x89, 0x50]), isFalse);
    expect(
      looksLikeMp4(const <int>[0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70]),
      isTrue,
    );
    expect(looksLikeMp4(const <int>[0, 0, 0, 0]), isFalse);
    expect(
      isInsideDirectoryPath(
        '/tmp/captures',
        '/tmp/captures/a.png',
        separator: '/',
      ),
      isTrue,
    );
    expect(
      isInsideDirectoryPath(
        '/tmp/captures',
        '/tmp/captures-other/a.png',
        separator: '/',
      ),
      isFalse,
    );
  });

  test('按系统选择打开方式', () {
    final windowsFile = localOpenRequest(
      r'C:\captures\a.mp4',
      openFile: true,
      operatingSystem: 'windows',
    );
    expect(windowsFile.executable, 'cmd.exe');
    expect(windowsFile.arguments, <String>[
      '/c',
      'start',
      '',
      r'C:\captures\a.mp4',
    ]);
    final windowsFolder = localOpenRequest(
      r'C:\captures',
      openFile: false,
      operatingSystem: 'windows',
    );
    expect(windowsFolder.executable, 'explorer.exe');
    expect(windowsFolder.ignoreExitCode, isTrue);
    expect(
      localOpenRequest(
        '/tmp/a.png',
        openFile: true,
        operatingSystem: 'macos',
      ).executable,
      'open',
    );
    expect(
      localOpenRequest(
        '/tmp/a.png',
        openFile: false,
        operatingSystem: 'linux',
      ).executable,
      'xdg-open',
    );
  });

  test('写入、列出并删除应用目录里的文件', () async {
    final directory = await Directory.systemTemp.createTemp(
      'fire_adb_capture_test',
    );
    try {
      final store = CaptureStore(directory);
      expect(await store.list(extension: 'png'), isEmpty);
      final png = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
      final older = await store.write('screenshot_old.png', png);
      final newer = await store.write('screenshot_new.png', png);
      await store.write('screenrecord.mp4', const <int>[1, 2, 3]);
      await older.setLastModified(DateTime.utc(2020, 1, 1));
      await newer.setLastModified(DateTime.utc(2024, 1, 1));
      expect(() => store.write('../escape.png', png), throwsArgumentError);
      final listed = await store.list(extension: 'png');
      expect(listed.map((file) => file.name), <String>[
        'screenshot_new.png',
        'screenshot_old.png',
      ]);
      await store.deleteFile(listed.last);
      expect(
        (await store.list(extension: 'png')).map((file) => file.name),
        <String>['screenshot_new.png'],
      );
      final outside = File(
        '${directory.parent.path}${Platform.pathSeparator}outside.png',
      );
      await outside.writeAsBytes(png);
      try {
        await expectLater(
          store.deleteFile(
            CaptureFile(
              path: outside.path,
              name: 'outside.png',
              size: png.length,
              modified: DateTime.utc(2024),
            ),
          ),
          throwsStateError,
        );
        expect(await outside.exists(), isTrue);
      } finally {
        if (await outside.exists()) await outside.delete();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
