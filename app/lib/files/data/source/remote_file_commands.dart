import 'dart:convert';

import '../bean/remote_file.dart';

const String remoteSearchMarker = '---FIRE-ADB---';

const int remoteTextEditLimit = 512 * 1024;

const String remoteStoragePath = '/sdcard';

const String remoteTempPath = '/data/local/tmp';

String quoteRemotePath(String value) => "'${value.replaceAll("'", r"'\''")}'";

String normalizeRemotePath(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return remoteStoragePath;
  final withSlash = trimmed.startsWith('/') ? trimmed : '/$trimmed';
  if (withSlash.length > 1 && withSlash.endsWith('/')) {
    return withSlash.substring(0, withSlash.length - 1);
  }
  return withSlash;
}

String parentRemotePath(String path) {
  final normalized = normalizeRemotePath(path);
  if (normalized == '/') return '/';
  final slash = normalized.lastIndexOf('/');
  if (slash <= 0) return '/';
  return normalized.substring(0, slash);
}

bool isSafeRemoteName(String name) {
  if (name.isEmpty || name == '.' || name == '..') return false;
  return !name.contains('/') && !name.contains('\u0000');
}

String joinRemotePath(String directory, String name) {
  if (!isSafeRemoteName(name)) {
    throw ArgumentError.value(name, 'name', '非法文件名');
  }
  final base = normalizeRemotePath(directory);
  if (base == '/') return '/$name';
  return '$base/$name';
}

String remoteBaseName(String path) {
  final normalized = normalizeRemotePath(path);
  final slash = normalized.lastIndexOf('/');
  if (slash < 0 || slash == normalized.length - 1) return normalized;
  return normalized.substring(slash + 1);
}

String? normalizeChmod(String input) {
  final trimmed = input.trim();
  if (!RegExp(r'^[0-7]{3,4}$').hasMatch(trimmed)) return null;
  return trimmed;
}

String formatPermission(int mode) {
  final bits = mode & 0x1ff;
  const letters = <String>['r', 'w', 'x'];
  final buffer = StringBuffer(bits.toRadixString(8).padLeft(3, '0'))
    ..write(' ');
  for (var i = 0; i < 9; i++) {
    final on = (bits & (1 << (8 - i))) != 0;
    buffer.write(on ? letters[i % 3] : '-');
  }
  return buffer.toString();
}

String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const kb = 1024;
  const mb = 1024 * 1024;
  const gb = 1024 * 1024 * 1024;
  if (bytes < mb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / gb).toStringAsFixed(1)} GB';
}

String formatRemoteTime(int seconds) {
  if (seconds <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

int compareRemoteFiles(RemoteFile a, RemoteFile b) {
  if (a.canEnter != b.canEnter) return a.canEnter ? -1 : 1;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// 用 `[ -d ]` 判断哪些路径能当目录进入。会跟随链接，所以 `/sdcard` 也能进来。
String directoryProbeCommand(Iterable<String> paths) {
  return paths
      .map((path) {
        final quoted = quoteRemotePath(path);
        return "if [ -d $quoted ]; then printf '%s\\n' $quoted; fi";
      })
      .join('; ');
}

Set<String> parseDirectoryProbe(String output) {
  return output
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.startsWith('/'))
      .toSet();
}

String escapeFindName(String keyword) {
  return keyword
      .replaceAll(r'\', r'\\')
      .replaceAll('*', r'\*')
      .replaceAll('?', r'\?')
      .replaceAll('[', r'\[');
}

String searchCommand(String directory, String keyword) {
  final pattern = quoteRemotePath('*${escapeFindName(keyword)}*');
  final dir = quoteRemotePath(normalizeRemotePath(directory));
  final marker = quoteRemotePath(remoteSearchMarker);
  return 'find $dir -maxdepth 8 -type d -name $pattern; '
      'echo $marker; '
      'find $dir -maxdepth 8 -type f -name $pattern; '
      'echo $marker; '
      'find $dir -maxdepth 8 -type l -name $pattern';
}

List<RemoteFile> parseSearchOutput(String output, {int limit = 300}) {
  final hits = <RemoteFile>[];
  var section = 0;
  for (final raw in output.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line == remoteSearchMarker) {
      section++;
      continue;
    }
    if (!line.startsWith('/')) continue;
    final mode = switch (section) {
      0 => 0x4000,
      2 => 0xa000,
      _ => 0x8000,
    };
    hits.add(
      RemoteFile(
        name: remoteBaseName(line),
        path: line,
        mode: mode,
        size: 0,
        mtime: 0,
        sizeKnown: false,
      ),
    );
    if (hits.length >= limit) break;
  }
  return hits;
}

String deleteCommand(Iterable<String> paths) {
  return 'rm -rf ${_quoted(paths)}';
}

String renameCommand(String from, String to) {
  return 'mv -f ${quoteRemotePath(from)} ${quoteRemotePath(to)}';
}

String copyCommand(Iterable<String> sources, String destination) {
  return 'cp -R -f ${_quoted(sources)} ${quoteRemotePath(destination)}';
}

String moveCommand(Iterable<String> sources, String destination) {
  return 'mv -f ${_quoted(sources)} ${quoteRemotePath(destination)}';
}

String chmodCommand(Iterable<String> paths, String mode) {
  final normalized = normalizeChmod(mode);
  if (normalized == null) {
    throw ArgumentError.value(mode, 'mode', '非法权限');
  }
  return 'chmod $normalized ${_quoted(paths)}';
}

String mkdirCommand(String path) => 'mkdir ${quoteRemotePath(path)}';

String touchCommand(String path) => 'touch ${quoteRemotePath(path)}';

void ensureCommandSuccess(String output) {
  final trimmed = output.trim();
  if (trimmed.isEmpty) return;
  throw StateError(trimmed);
}

bool looksLikeBinary(List<int> bytes) {
  if (bytes.contains(0)) return true;
  try {
    utf8.decode(bytes);
    return false;
  } on FormatException {
    return true;
  }
}

String _quoted(Iterable<String> paths) => paths.map(quoteRemotePath).join(' ');
