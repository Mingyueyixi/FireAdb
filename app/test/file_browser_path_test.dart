import 'package:fireadb/files/files_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('应用目录不能离开固定根', () {
    const root = '/data/user/0/com.example.app';
    expect(fencedRemotePath(root, '$root/cache'), '$root/cache');
    expect(fencedRemotePath(root, '/data/user/0'), root);
    expect(fencedRemotePath(root, '$root/../com.other'), root);
    expect(fencedRemotePath(null, '/sdcard/Download'), '/sdcard/Download');
  });
}
