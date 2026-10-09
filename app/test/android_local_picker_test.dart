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
    expect(
      parentLocalPath(r'C:\Users\Mi\Downloads\FireAdb'),
      'C:/Users/Mi/Downloads',
    );
    expect(parentLocalPath('C:/Users'), 'C:/');
    expect(parentLocalPath('C:/'), windowsDrivesPath);
    expect(parentLocalPath('C:'), windowsDrivesPath);
    expect(parentLocalPath(windowsDrivesPath), isNull);
  });

  test('子路径留在正在浏览的目录下', () {
    expect(
      joinLocalChild(r'C:\Users\Mi\Downloads', 'FireAdb'),
      'C:/Users/Mi/Downloads/FireAdb',
    );
    expect(joinLocalChild('C:/', 'Users'), 'C:/Users');
  });

  test('盘符列表能读出多块盘', () {
    expect(parseWindowsDrives(r'Drives: C:\ D:\'), <String>['C:/', 'D:/']);
    expect(parseWindowsDrives('驱动器: C:\\ E:\\'), <String>['C:/', 'E:/']);
  });

  test('本机路径取最后一段', () {
    expect(localEntryName(r'C:\Users\Mi\Downloads'), 'Downloads');
    expect(localEntryName('/sdcard/Download/FireAdb'), 'FireAdb');
    expect(localEntryName('C:/'), 'C:/');
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
    expect(normalizeLocalPath(r'C:\Users\Mi\'), 'C:/Users/Mi');
    expect(normalizeLocalPath('C:/'), 'C:/');
  });
}
