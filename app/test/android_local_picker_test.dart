import 'package:fire_adb/files/android_local_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('上级目录可以回到根目录 /', () {
    expect(parentLocalPath('/storage/emulated/0/Download'), primaryStoragePath);
    expect(parentLocalPath('$primaryStoragePath/'), '/storage/emulated');
    expect(parentLocalPath(primaryStoragePath), '/storage/emulated');
    expect(parentLocalPath('/storage/emulated'), '/storage');
    expect(parentLocalPath('/storage'), '/');
    expect(parentLocalPath('/sdcard/Download/FireAdb'), '/sdcard/Download');
    expect(parentLocalPath('/sdcard'), '/');
    expect(parentLocalPath('/storage/ABCD-1234/DCIM'), '/storage/ABCD-1234');
    expect(
      parentLocalPath('/storage/emulated/0/Android/data'),
      '/storage/emulated/0/Android',
    );
    expect(parentLocalPath('/'), isNull);
  });

  test('新建名称不能是路径', () {
    expect(isSafeLocalName('za'), isTrue);
    expect(isSafeLocalName(''), isFalse);
    expect(isSafeLocalName('.'), isFalse);
    expect(isSafeLocalName('..'), isFalse);
    expect(isSafeLocalName('a/b'), isFalse);
    expect(isSafeLocalName(r'a\b'), isFalse);
  });

  test('路径去掉末尾斜杠', () {
    expect(normalizeLocalPath(r'/sdcard/Download/'), '/sdcard/Download');
    expect(normalizeLocalPath('/'), '/');
  });
}
