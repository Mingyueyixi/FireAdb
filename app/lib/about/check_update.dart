import 'dart:convert';
import 'dart:io';

import 'project.dart';

/// 一次检查更新发现的新版本。没有新版本时返回 null。
class ReleaseUpdate {
  const ReleaseUpdate({required this.version, required this.url});

  /// 发布标签（如 `v1.1.0`）。
  final String version;

  /// 发布页地址，直接交给浏览器打开。
  final String url;
}

/// 查询最新发布版本并与 [currentVersion] 比较。
///
/// 仓库尚无任何发布（404）或本地已是最新时返回 null。
/// 只做“发现 + 引导”：桌面与 Linux/Windows 分发都是压缩包，应用内
/// 无法替换正在运行的程序，替换包仍由用户手动完成。
Future<ReleaseUpdate?> fetchLatestRelease({String? currentVersion}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(Uri.parse(projectReleasesApi));
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode == HttpStatus.notFound) {
      // 仓库还没有发布过任何 Release（未打 tag 时 releases/latest 即 404）。
      // 这是正常状态而非错误：视为没有可用更新。
      await response.drain<void>();
      return null;
    }
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('GitHub API HTTP ${response.statusCode}');
    }
    final body = await response.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final tag = json['tag_name'] as String? ?? '';
    if (tag.isEmpty) return null;
    final release = ReleaseUpdate(
      version: tag,
      url: json['html_url'] as String? ?? projectHomepage,
    );
    if (currentVersion == null || !_isSemantic(currentVersion)) {
      // 本地版本读不出来或不是数字版本号时，直接把发布页交给用户判断。
      return release;
    }
    return _isNewer(tag, currentVersion) ? release : null;
  } finally {
    client.close();
  }
}

bool _isSemantic(String version) {
  final parts = version.replaceFirst(RegExp(r'^v'), '').split('.');
  return parts.length >= 2 && parts.every((part) => int.tryParse(part) != null);
}

bool _isNewer(String latest, String current) {
  List<int> parse(String value) => value
      .replaceFirst(RegExp(r'^v'), '')
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList();
  final a = parse(latest);
  final b = parse(current);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
