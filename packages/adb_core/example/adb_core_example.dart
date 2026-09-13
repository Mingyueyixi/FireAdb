import 'package:adb_core/adb_core.dart';

void main() {
  final msg = AdbMessage(commandCnxn, version, maxAdbData, [0x41, 0x42, 0x43]);
  print('CNXN message: $msg');
  print('checksum: ${msg.checksum}');
  print('packed: ${msg.pack().length} bytes');
}