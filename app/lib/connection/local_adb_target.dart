/// 安卓进程上，这条已经建立的 ADB 连接指向本机回环地址时，文件就在本地。
bool shouldCopyLocally({
  required bool runningOnAndroid,
  String? host,
  String? serial,
  String? adbSerial,
}) {
  if (!runningOnAndroid) return false;
  for (final value in <String?>[host, serial, adbSerial]) {
    final text = value?.trim();
    if (text == null || text.isEmpty) continue;
    final endpoint = endpointHost(text);
    if (endpoint != null && isLoopbackHost(endpoint)) return true;
  }
  return false;
}

/// 从 `host:port` 或 `[ipv6]:port` 取出主机。没有端口时返回原值。
String? endpointHost(String value) {
  final text = value.trim();
  if (text.isEmpty) return null;
  if (text.startsWith('[')) {
    final end = text.indexOf(']');
    if (end > 1) return text.substring(1, end);
    return text;
  }
  final colon = text.lastIndexOf(':');
  if (colon > 0 &&
      text.indexOf(':') == colon &&
      int.tryParse(text.substring(colon + 1)) != null) {
    return text.substring(0, colon);
  }
  return text;
}

bool isLoopbackHost(String host) {
  final normalized = host.trim().toLowerCase();
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1' ||
      normalized == '0:0:0:0:0:0:0:1';
}
