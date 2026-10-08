import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';

import '../capture/data/capture_paths.dart';
import 'android_local_picker.dart';
import 'android_storage_access.dart';

/// 从本机选择要上传的文件。取消时返回空列表。
///
/// Android 用应用内目录列表，拿到真实路径后再用本地文件接口读取。
/// Windows 上不用 file_selector。它的对话框挂在 Flutter 窗口上，
/// 弹出时辅助功能树更新失败，选文件会直接抛错。
Future<List<String>> pickLocalFiles(BuildContext context) async {
  if (Platform.isAndroid) return pickAndroidFiles(context);
  if (Platform.isWindows) return _pickWindowsFiles();
  final picked = await openFiles();
  return picked.map((file) => file.path).toList();
}

/// 从本机选择一个目录。取消时返回 null。
///
/// Android 用应用内目录列表。macOS、Linux 用系统目录窗口。
/// Windows 与选文件同一原因，改用系统的文件夹对话框。
Future<String?> pickLocalDirectory(
  BuildContext context, {
  String? initialDirectory,
  String? prompt,
}) async {
  if (Platform.isAndroid) {
    return pickAndroidDirectory(
      context,
      initialDirectory: initialDirectory,
      prompt: prompt,
    );
  }
  final initial = _existingDirectory(initialDirectory);
  if (Platform.isWindows) {
    return _pickWindowsDirectory(initial: initial, prompt: prompt);
  }
  return getDirectoryPath(initialDirectory: initial);
}

/// 打开目录选择，起始位置是导出目录。取消时返回 null。
Future<String?> pickExportDirectory(BuildContext context, String prompt) async {
  final initial =
      exportDirectoryPath(Platform.environment) ?? Directory.systemTemp.path;
  if (Platform.isAndroid) {
    final granted = await ensureAllFilesAccess(context);
    if (!granted || !context.mounted) return null;
  }
  try {
    await Directory(initial).create(recursive: true);
  } catch (_) {}
  if (!context.mounted) return null;
  return pickLocalDirectory(context, initialDirectory: initial, prompt: prompt);
}

String? _existingDirectory(String? path) {
  final trimmed = path?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (Directory(trimmed).existsSync()) return trimmed;
  return null;
}

/// PowerShell 管道有时是 UTF-16。Base64 只有 ASCII，两种编码都要能读。
String decodeProcessText(List<int> bytes) {
  if (bytes.contains(0)) {
    var start = 0;
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) start = 2;
    final units = <int>[];
    for (var i = start; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }
  return utf8.decode(bytes);
}

/// 每行是一条 UTF-8 路径的 Base64。无法解码的行跳过。
List<String> decodePickedPaths(String output) {
  final paths = <String>[];
  for (final raw in output.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    try {
      paths.add(utf8.decode(base64.decode(line)));
    } on FormatException {
      continue;
    }
  }
  return paths;
}

Future<List<String>> _pickWindowsFiles() async {
  const script = r'''
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Add-Type -AssemblyName System.Windows.Forms
$owner = New-Object System.Windows.Forms.Form
$owner.TopMost = $true
$owner.ShowInTaskbar = $false
$owner.Opacity = 0
$null = $owner.Show()
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Multiselect = $true
$dialog.Filter = "All files (*.*)|*.*"
$result = $dialog.ShowDialog($owner)
$owner.Close()
if ($result -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }
foreach ($name in $dialog.FileNames) {
  [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($name))
}
''';
  final result = await Process.run(
    'powershell.exe',
    <String>['-NoProfile', '-STA', '-Command', script],
    stdoutEncoding: null,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    final detail = '${result.stderr}'.trim();
    throw StateError(detail.isEmpty ? '无法打开文件选择窗口' : detail);
  }
  final stdout = result.stdout;
  final text = stdout is String
      ? stdout
      : decodeProcessText(stdout as List<int>);
  return decodePickedPaths(text);
}

Future<String?> _pickWindowsDirectory({String? initial, String? prompt}) async {
  const script = r'''
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Add-Type -AssemblyName System.Windows.Forms
$owner = New-Object System.Windows.Forms.Form
$owner.TopMost = $true
$owner.ShowInTaskbar = $false
$owner.Opacity = 0
$null = $owner.Show()
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.ShowNewFolderButton = $true
$dialog.UseDescriptionForTitle = $true
if ($env:FIRE_ADB_PROMPT) { $dialog.Description = $env:FIRE_ADB_PROMPT }
if ($env:FIRE_ADB_DIR -and (Test-Path -LiteralPath $env:FIRE_ADB_DIR)) {
  $dialog.SelectedPath = $env:FIRE_ADB_DIR
}
$result = $dialog.ShowDialog($owner)
$owner.Close()
if ($result -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }
[Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($dialog.SelectedPath))
''';
  final result = await Process.run(
    'powershell.exe',
    <String>['-NoProfile', '-STA', '-Command', script],
    stdoutEncoding: null,
    stderrEncoding: utf8,
    environment: <String, String>{
      ...Platform.environment,
      'FIRE_ADB_DIR': initial ?? '',
      'FIRE_ADB_PROMPT': prompt ?? '',
    },
  );
  if (result.exitCode != 0) {
    final detail = '${result.stderr}'.trim();
    throw StateError(detail.isEmpty ? '无法打开文件夹选择窗口' : detail);
  }
  final stdout = result.stdout;
  final text = stdout is String
      ? stdout
      : decodeProcessText(stdout as List<int>);
  final paths = decodePickedPaths(text);
  if (paths.isEmpty) return null;
  return paths.first;
}
