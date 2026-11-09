import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/fireadb_localizations_ext.dart';
import '../log/app_log.dart';
import 'build_info.dart';
import 'check_update.dart';
import 'project.dart';

/// 应用身份与更新入口：版本/构建信息、项目主页、检查更新。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  PackageInfo? _info;
  var _checking = false;

  /// 上次检查更新的结果，行内展示在「检查更新」行下方，直到下次检查。
  String? _resultMessage;
  var _resultIsError = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _info = info);
    } catch (error, stackTrace) {
      log.severe('读取应用版本失败', error, stackTrace);
    }
  }

  /// 检查更新这类页面内操作，结果直接显示在触发行下方：
  /// 不用全局 Snackbar（浮在底部导航栏上方、定时消失，与本页动作脱节）。
  void _showResult(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _resultMessage = message;
      _resultIsError = isError;
    });
  }

  Future<void> _openLink(String url) async {
    final l10n = context.l10n;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (error, stackTrace) {
      log.severe('打开链接失败：$url', error, stackTrace);
      _showResult(l10n.aboutOpenLinkFailed('$error'), isError: true);
    }
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    final l10n = context.l10n;
    setState(() {
      _checking = true;
      _resultMessage = null;
    });
    try {
      final release = await fetchLatestRelease(
        currentVersion: _info?.version,
      );
      if (!mounted) return;
      if (release == null) {
        _showResult(l10n.aboutCheckUpdateLatest);
        return;
      }
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.aboutCheckUpdateFoundTitle),
          content: Text(
            l10n.aboutCheckUpdateFoundMessage(
              release.version,
              _info?.version ?? l10n.aboutVersionUnknown,
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.aboutGoRelease),
            ),
          ],
        ),
      );
      if (go == true) await _openLink(release.url);
    } catch (error, stackTrace) {
      log.severe('检查更新失败', error, stackTrace);
      _showResult(l10n.aboutCheckUpdateFailed('$error'), isError: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// 构建时间戳格式化为本地时间（yyyy-MM-dd HH:mm）。
  String _formatBuildTime() {
    final epoch = BuildInfo.buildEpoch;
    if (epoch == null) return BuildInfo.buildTime;
    final time = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  /// 显示版本：v + pubspec 版本 + 短提交号（如 v1.0.0-6cd4595）。
  /// pubspec 的版本必须保持纯净语义（检查更新按它比较），
  /// 提交号只在显示时拼上；缺失/unknown 时退回 v+纯版本号。
  String _displayVersion(PackageInfo info) {
    final commit = BuildInfo.gitCommit;
    if (commit.isEmpty || commit == 'unknown') return 'v${info.version}';
    return 'v${info.version}-$commit';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final info = _info;
    final mono = theme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: <Widget>[
            Image.asset('assets/icon/flame_master.png', width: 56, height: 56),
            const SizedBox(height: 12),
            Text(
              'FireAdb',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.aboutDescription,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  ListTile(
                    title: Text(l10n.aboutVersionLabel),
                    trailing: Text(
                      info == null
                          ? l10n.aboutVersionUnknown
                          : _displayVersion(info),
                      style: mono,
                    ),
                  ),
                  if (info != null && info.buildNumber.isNotEmpty)
                    ListTile(
                      title: Text(l10n.aboutBuild),
                      trailing: Text(info.buildNumber, style: mono),
                    ),
                  if (!BuildInfo.isDevBuild)
                    ListTile(
                      title: Text(l10n.aboutBuildTime),
                      trailing: Text(_formatBuildTime(), style: mono),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  ListTile(
                    leading: _checking
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.update),
                    title: Text(l10n.aboutCheckUpdate),
                    // 结果右对齐（与信息卡值的方位一致），行高不变，
                    // 避免结果出现/消失时下方内容上下跳动。
                    trailing: _resultMessage == null
                        ? null
                        : ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 170),
                            child: Text(
                              _resultMessage!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: _resultIsError
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                    onTap: _checking ? null : () => unawaited(_checkUpdate()),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.home_outlined),
                    title: Text(l10n.aboutHomepage),
                    // 专用链接蓝（与主题 primary 解耦）+ 下划线，保证可点击
                    // 语义在任何主题下都醒目。
                    subtitle: Text(
                      projectHomepage,
                      style: TextStyle(
                        color: theme.brightness == Brightness.dark
                            ? const Color(0xFF7FB8FF)
                            : const Color(0xFF0B57D0),
                        decoration: TextDecoration.underline,
                      ),
                    ),
                    onTap: () => unawaited(_openLink(projectHomepage)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
