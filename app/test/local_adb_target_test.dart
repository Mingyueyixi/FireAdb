import 'package:fire_adb/connection/local_adb_target.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('连到本机回环地址时直接复制', () {
    expect(
      shouldCopyLocally(
        runningOnAndroid: true,
        host: '127.0.0.1',
        serial: '3B6F42E7NT8RZL34',
      ),
      isTrue,
    );
    expect(
      shouldCopyLocally(
        runningOnAndroid: true,
        host: 'localhost',
        serial: 'adb',
      ),
      isTrue,
    );
    expect(
      shouldCopyLocally(runningOnAndroid: true, host: '[::1]', serial: 'adb'),
      isTrue,
    );
    expect(
      shouldCopyLocally(runningOnAndroid: true, host: '::1', serial: 'adb'),
      isTrue,
    );
    expect(
      shouldCopyLocally(
        runningOnAndroid: true,
        serial: '127.0.0.1:5555',
      ),
      isTrue,
    );
  });

  test('连到其他地址或非安卓进程仍走 ADB', () {
    expect(
      shouldCopyLocally(
        runningOnAndroid: true,
        host: '192.168.3.45',
        serial: '3B6F42E7NT8RZL34',
      ),
      isFalse,
    );
    expect(
      shouldCopyLocally(
        runningOnAndroid: false,
        host: '127.0.0.1',
        serial: '3B6F42E7NT8RZL34',
      ),
      isFalse,
    );
  });
}
