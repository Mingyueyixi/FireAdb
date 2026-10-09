/// ADB 传输层协议常量。
///
/// 参考：
/// - AOSP `docs/dev/protocol.md`（消息头与命令定义）
/// - AOSP `adb.h`（协议版本常量）
library;

/// 消息头固定 24 字节 = 6 × uint32（小端）。
const int messageHeaderSize = 24;

/// 单条消息最大 payload（host 在 CNXN 中声明的 maxdata）。
const int maxAdbData = 256 * 1024;

/// 传输层可接受的最小协议版本。
const int versionMin = 0x01000000;

/// 支持跳过 checksum（data_check 置 0）的协议版本。
const int versionSkipChecksum = 0x01000001;

/// 当前实现使用的协议版本。
const int version = versionSkipChecksum;

/// AUTH 消息 arg0 取值。
const int authToken = 1;
const int authSignature = 2;
const int authRsaPublicKey = 3;

/// 各命令的线上（wire）小端整数值。
const int commandSync = 0x434e5953;
const int commandCnxn = 0x4e584e43;
const int commandAuth = 0x48545541;
const int commandOpen = 0x4e45504f;
const int commandOkay = 0x59414b4f;
const int commandClose = 0x45534c43;
const int commandWrite = 0x45545257;
const int commandStls = 0x534c5453;

/// `A_STLS_VERSION`。arg0 为 `0x01000000`。
const int stlsVersion = 0x01000000;

/// 线上整数值 -> 人类可读命令名（调试用）。
const Map<int, String> commandNames = {
  commandSync: 'SYNC',
  commandCnxn: 'CNXN',
  commandAuth: 'AUTH',
  commandOpen: 'OPEN',
  commandOkay: 'OKAY',
  commandClose: 'CLSE',
  commandWrite: 'WRTE',
  commandStls: 'STLS',
};
