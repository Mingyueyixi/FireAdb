import 'dart:convert';
import 'dart:typed_data';

import 'package:fireadb/apps/data/bean/installed_app.dart';
import 'package:fireadb/apps/loader/app_display_loader.dart';
import 'package:fireadb/appservice/fire_app_service.dart';
import 'package:fireadb/appservice/protocol/fire_app_message.dart';
import 'package:fireadb/link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('只有常驻的应用服务算已有进程', () {
    expect(
      fireAppServiceProcess(
        'app_process /system/bin com.fire.adb.appservice.FireAppService link=28170',
      ),
      isTrue,
    );
    expect(
      fireAppServiceProcess(
        'app_process /system/bin com.fire.adb.appservice.ScreenRecorder --output /sdcard/a.mp4',
      ),
      isFalse,
    );
  });

  test('cmdline 以空字节分隔时仍能认出常驻服务', () {
    expect(
      fireAppServiceProcess(
        'app_process\u0000/system/bin\u0000com.fire.adb.appservice.FireAppService\u0000link=28170',
      ),
      isTrue,
    );
    expect(fireAppServiceProcess('No such file or directory'), isFalse);
  });

  test('常驻服务脱离 adb 会话后在后台启动', () {
    final command = fireAppServiceDaemonCommand(
      '/data/local/tmp/fire-app-service.jar',
      argument: 'link=28170 token=abc',
    );
    expect(command, contains('setsid'));
    expect(command, contains('com.fire.adb.appservice.FireAppService'));
    expect(command, contains('link=28170 token=abc'));
    expect(command, contains('&'));
  });

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

  test('hello 的 JSON 正文是 16 字节，头和正文用冒号分开', () {
    final response = FireDataResponse.json(
      name: 'clipboard.data',
      id: 1,
      body: <String, String>{'text': 'hello'},
    );
    final bytes = response.bytes;
    expect(
      ascii.decode(bytes),
      'clipboard.data json 1 16:{"text":"hello"}',
    );
    expect(response.display, 'clipboard.data json 1 16:{"text":"hello"}');
    expect(
      FireDataRequest.none(name: 'clipboard.get', id: 1).display,
      'clipboard.get none 1 0:',
    );
  });

  test('分片到达时仍能解析，正文里的冒号和换行不算下一条', () {
    final clip = jsonEncode(<String, String>{
      'text': '剪贴板内容 line2\n中文:ok',
    });
    final bytes = Uint8List.fromList(<int>[
      ...FireDataResponse.text(name: 'session.ready', id: 0, body: '1').bytes,
      ...FireDataResponse.json(
        name: 'clipboard.data',
        id: 1,
        body: jsonDecode(clip) as Map<String, dynamic>,
      ).bytes,
      ...FireDataResponse.none(name: 'clipboard.ok', id: 1).bytes,
      ...FireDataResponse.text(name: 'session.error', id: 1, body: '未知命令').bytes,
    ]);
    final reader = FireDataResponseReader();
    final messages = <FireDataResponse>[];
    for (final byte in bytes) {
      messages.addAll(reader.add(<int>[byte]));
    }
    expect(messages, hasLength(4));
    expect(messages[0].name, 'session.ready');
    expect(messages[0].text, '1');
    expect(messages[1].name, 'clipboard.data');
    expect(jsonDecode(messages[1].text)['text'], '剪贴板内容 line2\n中文:ok');
    expect(messages[2].name, 'clipboard.ok');
    expect(messages[2].type, 'none');
    expect(messages[2].body, isEmpty);
    expect(utf8.encode('未知命令'), hasLength(12));
    expect(messages[3].text, '未知命令');
    expect(reader.pendingBytes, 0);
  });

  test('头没到冒号时先等着', () {
    final bytes = FireDataResponse.json(
      name: 'clipboard.data',
      id: 1,
      body: <String, String>{'text': 'hello clipboard'},
    ).bytes;
    final reader = FireDataResponseReader();
    expect(reader.add(bytes.sublist(0, 12)), isEmpty);
    final message = reader.add(bytes.sublist(12)).single;
    expect(jsonDecode(message.text)['text'], 'hello clipboard');
  });

  test('catalog.app 解析出名称、版本、标记和体积', () {
    final message = FireDataResponseReader()
        .add(
          FireDataResponse.json(
            name: 'catalog.app',
            id: 4,
            body: <String, Object>{
              'package': 'com.example.app',
              'label': '示例',
              'versionName': '1.2.3',
              'versionCode': 12,
              'system': false,
              'disabled': false,
              'suspended': false,
              'debuggable': true,
              'apk': <String>['/data/app/com.example.app/base.apk'],
              'size': 4096,
            },
          ).bytes,
        )
        .single;
    final summary = fireAppSummaryFromJson(_json(message));
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

  test('没有版本号、体积为 0、空图标时对应字段为空', () {
    final shown = fireAppShowFromJson(
      <String, Object>{
        'package': 'com.example.app',
        'label': '',
        'versionName': '',
        'system': true,
        'disabled': false,
        'suspended': true,
        'debuggable': true,
        'apk': <String>[],
        'size': 0,
        'dataDir': '/data/user/0/com.example.app',
        'cacheDir': '/data/user/0/com.example.app/cache',
        'externalDir': '/sdcard/Android/data/com.example.app',
      },
      png: Uint8List(0),
    );
    expect(shown.versionCode, isNull);
    expect(shown.png, isNull);
    expect(shown.isSystem, isTrue);
    expect(shown.isSuspended, isTrue);
    expect(shown.isDisabledUser, isFalse);
    expect(shown.isDebuggable, isTrue);
    expect(shown.dataDir, '/data/user/0/com.example.app');
    expect(shown.cacheDir, '/data/user/0/com.example.app/cache');
    expect(shown.externalDir, '/sdcard/Android/data/com.example.app');
  });

  test('列表一次带全部包名，应用名另一次返回', () {
    final list = FireDataResponseReader()
        .add(
          FireDataResponse.json(
            name: 'catalog.apps',
            id: 4,
            body: <String, Object>{
              'items': <Map<String, Object>>[_app(label: '')],
            },
          ).bytes,
        )
        .single;
    final summaries = fireAppSummariesFromJson(_json(list));
    expect(summaries, hasLength(1));
    expect(summaries.single.packageName, 'com.android.settings');
    expect(summaries.single.label, isEmpty);

    final names = FireDataResponseReader()
        .add(
          FireDataResponse.json(
            name: 'catalog.names',
            id: 6,
            body: <String, Object>{
              'items': <Map<String, Object>>[
                <String, String>{
                  'package': 'com.android.settings',
                  'label': '设置',
                },
              ],
            },
          ).bytes,
        )
        .single;
    final parsed = fireAppNamesFromJson(_json(names));
    expect(parsed.single.packageName, 'com.android.settings');
    expect(parsed.single.label, '设置');
  });

  test('剪贴板 JSON 保留 emoji', () {
    const text = '你好 😀\n家族👨‍👩‍👧‍👦';
    final bytes = FireDataRequest.json(
      name: 'clipboard.set',
      id: 3,
      body: <String, String>{'text': text},
    ).bytes;
    final message = FireDataResponseReader().add(bytes).single;
    expect(message.json['text'], text);
  });

  test('剪贴板历史是 JSON 数组，新的在前', () {
    final message = FireDataResponseReader()
        .add(
          FireDataResponse.json(
            name: 'clipboard.history',
            id: 2,
            body: <String, Object>{
              'items': <String>['最新一条', 'second', '第一条\n多行'],
            },
          ).bytes,
        )
        .single;
    expect(jsonDecode(message.text)['items'], <String>[
      '最新一条',
      'second',
      '第一条\n多行',
    ]);
  });

  test('历史消息拆成两段仍能拼上', () {
    final bytes = FireDataResponse.json(
      name: 'clipboard.history',
      id: 2,
      body: <String, Object>{
        'items': <String>['alpha', 'beta'],
      },
    ).bytes;
    final reader = FireDataResponseReader();
    expect(reader.add(bytes.sublist(0, 12)), isEmpty);
    final message = reader.add(bytes.sublist(12)).single;
    expect(jsonDecode(message.text)['items'], <String>['alpha', 'beta']);
  });
}

Map<String, dynamic> _json(FireDataResponse message) => message.json;

Map<String, Object> _app({required String label}) {
  return <String, Object>{
    'package': 'com.android.settings',
    'label': label,
    'versionName': '14',
    'versionCode': 34,
    'system': true,
    'disabled': false,
    'suspended': false,
    'debuggable': false,
    'apk': <String>['/system/priv-app/Settings/Settings.apk'],
    'size': 12345678,
  };
}
