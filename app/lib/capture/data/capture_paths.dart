import 'dart:io';

/// 截图、录像和导出文件放在用户的下载目录 `Downloads/FireAdb`。
///
/// Windows 没有 `HOME` 时改用 `USERPROFILE`。ADB 密钥仍放在配置目录，不和这些文件混在一起。
/// Android 使用公共下载目录，而不是应用私有缓存。
const String kFireAdbConfigName = 'fire_adb';
const String kFireAdbDataFolder = 'FireAdb';
const String kCapturesFolderName = 'captures';

/// 公共下载目录。系统实际目录名是 `Download`，有的设备也使用 `Downloads`。
const List<String> kAndroidDownloadCandidates = <String>[
  '/sdcard/Download',
  '/sdcard/Downloads',
  '/storage/emulated/0/Download',
  '/storage/emulated/0/Downloads',
];

/// 和文件管理一样，先在共享存储里建自己的目录。
const String kDeviceCaptureDir = '/sdcard/FireAdb';

/// shell 属主的目录。系统录屏无法在原处执行时，程序副本和临时 mp4 放在这里。
const String kShellTempDir = '/data/local/tmp';

/// 系统录屏的副本。文件名不是 `screenrecord`，停止时只向它发信号。
/// 已有这个文件就直接用，没有才从系统复制，录完后保留。
const String kShellRecorderName = 'fireadb_sr';

const String kShellRecorderPath = '$kShellTempDir/$kShellRecorderName';

/// 新文件落在这个目录上时应有的标签。出现 `screen_record` 就不能执行。
const String kShellRecorderContext = 'u:object_r:shell_data_file:s0';

/// Android 13（API 33）及更早只接受 1 到 180 秒。
const int kMaxScreenrecordSeconds = 180;

/// Android 14（API 34）起 `--time-limit 0` 表示不限时。
const int kUnlimitedScreenrecordSdk = 34;

const int kUnlimitedScreenrecordSeconds = 0;

const List<int> kScreenrecordLimits = <int>[30, 60, 180];

/// 录屏来源。系统录屏在会被策略接管时自行改用临时目录里的副本。
/// 投屏录屏先留在界面上，预览和远程操作接入后再启用。
enum ScreenRecordMethod { system, builtin, scrcpy }

/// 内置录屏和辅助服务共用这一份 jar。
const String kBuiltinRecorderJar = '/data/local/tmp/fire-app-service.jar';

const String kBuiltinRecorderClass = 'com.fire.adb.appservice.ScreenRecorder';

/// 内置录屏看到这个文件就写完 mp4 再退出。不能对 `app_process` 发信号，
/// 应用信息服务也是这个进程名。
const String kBuiltinRecordStopPath = '/data/local/tmp/fireadb_rec.stop';

/// 整段读入内存再落盘，限制单次录像大小，避免一次占用过多内存。
const int kMaxRecordingBytes = 1024 * 1024 * 1024;

const String kScreencapCommand = 'screencap -p';

const List<int> _pngSignature = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
];

String? homeDirectory(Map<String, String> environment) {
  for (final key in const <String>['HOME', 'USERPROFILE']) {
    final value = environment[key]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

String? exportDirectoryPath(
  Map<String, String> environment, {
  String? separator,
  bool? android,
  bool Function(String path)? directoryExists,
}) {
  if (android ?? Platform.isAndroid) {
    return '${androidDownloadDirectory(directoryExists)}/$kFireAdbDataFolder';
  }
  final root = _trimmedHome(environment);
  if (root == null) return null;
  final sep = separator ?? Platform.pathSeparator;
  return '$root${sep}Downloads$sep$kFireAdbDataFolder';
}

String? captureDirectoryPath(
  Map<String, String> environment, {
  String? separator,
  bool? android,
  bool Function(String path)? directoryExists,
}) {
  final export = exportDirectoryPath(
    environment,
    separator: separator,
    android: android,
    directoryExists: directoryExists,
  );
  if (export == null) return null;
  final sep = (android ?? Platform.isAndroid)
      ? '/'
      : (separator ?? Platform.pathSeparator);
  return '$export$sep$kCapturesFolderName';
}

String androidDownloadDirectory(bool Function(String path)? directoryExists) {
  final exists = directoryExists ?? ((String path) => Directory(path).existsSync());
  for (final candidate in kAndroidDownloadCandidates) {
    if (exists(candidate)) return candidate;
  }
  return kAndroidDownloadCandidates.first;
}

String? _trimmedHome(Map<String, String> environment) {
  final home = homeDirectory(environment);
  if (home == null) return null;
  if (home.length > 1 && (home.endsWith('/') || home.endsWith(r'\'))) {
    return home.substring(0, home.length - 1);
  }
  return home;
}

String quoteShell(String value) => "'${value.replaceAll("'", r"'\''")}'";

bool isSafeCaptureName(String name) {
  if (name.isEmpty || name == '.' || name == '..') return false;
  return !name.contains('/') &&
      !name.contains(r'\') &&
      !name.contains('\u0000');
}

String captureFileName({
  required String prefix,
  required DateTime time,
  required String serial,
  required String extension,
}) {
  final safeSerial = serial.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return '${prefix}_${_stamp(time)}_$safeSerial.$extension';
}

bool captureFileMatchesDevice(String name, String serial) {
  final safeSerial = serial.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final match = RegExp(r'^(?:screenshot|screenrecord)_\d{8}_\d{6}_(.+)\.[^.]+$')
      .firstMatch(name);
  return match != null && match.group(1) == safeSerial;
}

String _stamp(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}${two(time.month)}${two(time.day)}_'
      '${two(time.hour)}${two(time.minute)}${two(time.second)}';
}

String formatElapsed(Duration duration) {
  final seconds = duration.inSeconds.abs();
  final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
  final remain = (seconds % 60).toString().padLeft(2, '0');
  return '$minutes:$remain';
}

String briefDeviceOutput(String text, {int maxLength = 1200}) {
  final cleaned = _readableDeviceOutput(text);
  final marked = <String>[
    for (final line in cleaned.split('\n'))
      if (line.contains('fireadb-record')) line,
  ];
  final chosen = marked.isEmpty ? cleaned : marked.join('\n');
  if (chosen.length <= maxLength) return chosen;
  return '${chosen.substring(0, maxLength)}…';
}

String _readableDeviceOutput(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (rune == 0x0a || rune == 0x09) {
      buffer.writeCharCode(rune);
      continue;
    }
    if (rune == 0x0d) {
      buffer.write('\n');
      continue;
    }
    if (rune < 0x20 || rune == 0x7f) continue;
    buffer.writeCharCode(rune);
  }
  return buffer
      .toString()
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}

int normalizeScreenrecordLimit(int seconds, {bool allowUnlimited = false}) {
  if (allowUnlimited) {
    if (seconds <= 0) return kUnlimitedScreenrecordSeconds;
    return seconds;
  }
  if (seconds < 1) return 1;
  if (seconds > kMaxScreenrecordSeconds) return kMaxScreenrecordSeconds;
  return seconds;
}

bool screenrecordAllowsUnlimited(int? sdk) =>
    sdk != null && sdk >= kUnlimitedScreenrecordSdk;

bool isSafeRemoteDir(String path) {
  if (!path.startsWith('/') || path.contains('//')) return false;
  final safe = RegExp(r'^[A-Za-z0-9._-]+$');
  for (final segment in path.split('/').skip(1)) {
    if (segment.isEmpty || segment == '.' || segment == '..') return false;
    if (!safe.hasMatch(segment)) return false;
  }
  return true;
}

/// 先建 `/sdcard/FireAdb`，再用和 `screenrecord` 一样的读写打开试一次。
///
/// `mkdir` / `touch` 成功不能说明录屏能写。`screenrecord` 用 `O_RDWR` 打开 mp4，
/// 共享存储上这个打开可能返回 EACCES，这时改到 `/data/local/tmp`。
String resolveScreenrecordDirCommand() {
  return '${_mkdirAndProbe(kDeviceCaptureDir)} '
      '${_mkdirAndProbe(kShellTempDir)} '
      'exit 1';
}

String _mkdirAndProbe(String directory) {
  final quotedDir = quoteShell(directory);
  final probe = quoteShell('$directory/fireadb_w');
  return 'mkdir -p $quotedDir 2>/dev/null; '
      'if exec 3<>$probe 2>/dev/null; then '
      'exec 3>&-; rm -f $probe; printf \'%s\\n\' $quotedDir; exit 0; fi;';
}

String? parseWritableDir(String output) {
  for (final line in output.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (isSafeRemoteDir(trimmed)) return trimmed;
  }
  return null;
}

String joinRemoteCapturePath(String directory, String fileName) {
  if (!isSafeRemoteDir(directory)) {
    throw ArgumentError.value(directory, 'directory', 'unsafe directory');
  }
  if (!isSafeCaptureName(fileName)) {
    throw ArgumentError.value(fileName, 'fileName', 'unsafe file name');
  }
  final root = directory.length > 1 && directory.endsWith('/')
      ? directory.substring(0, directory.length - 1)
      : directory;
  return '$root/$fileName';
}

String screenrecordCommand({
  required String remotePath,
  required int timeLimitSeconds,
  bool allowUnlimited = false,
}) {
  final limit = normalizeScreenrecordLimit(
    timeLimitSeconds,
    allowUnlimited: allowUnlimited,
  );
  return 'screenrecord --time-limit $limit ${quoteShell(remotePath)}';
}

/// 同时读取录屏程序标签和系统版本，避免执行 `screenrecord`。
String recordingDeviceProbeCommand() =>
    '${systemScreenrecordContextCommand()}; printf \'\\n---\\n\'; '
    'getprop ro.build.version.sdk';

typedef RecordingDeviceProbe = ({bool needsShellCopy, int? sdk});

RecordingDeviceProbe parseRecordingDeviceProbe(String output) {
  final normalized = output.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  const marker = '\n---\n';
  final index = normalized.lastIndexOf(marker);
  if (index < 0) {
    return (
      needsShellCopy: systemScreenrecordNeedsShellCopy(normalized),
      sdk: int.tryParse(normalized.trim()),
    );
  }
  final listing = normalized.substring(0, index);
  final sdkText = normalized.substring(index + marker.length).trim();
  return (
    needsShellCopy: systemScreenrecordNeedsShellCopy(listing),
    sdk: int.tryParse(sdkText),
  );
}

const String kSystemScreenrecordPath = '/system/bin/screenrecord';

/// 只读取标签，不执行程序。`screen_record` 域里的进程会卡住，而且 shell 结束不了。
String systemScreenrecordContextCommand() =>
    'ls -Z ${quoteShell(kSystemScreenrecordPath)}';

bool systemScreenrecordNeedsShellCopy(String listing) {
  return listing.contains('screen_record');
}

/// 临时目录里已有录屏程序就只检查标签。没有才从系统复制，新文件留在 shell 域里。
String installShellRecorderCommand() {
  final path = quoteShell(kShellRecorderPath);
  final system = quoteShell(kSystemScreenrecordPath);
  return 'if [ -e $path ]; then ls -Z $path; '
      'else cp $system $path && chmod 755 $path && ls -Z $path; fi';
}

/// 标签必须是 [kShellRecorderContext]。`screen_record` 域里的进程无法被 shell 结束。
bool shellRecorderContextIsSafe(String listing) {
  final text = listing.trim();
  if (!text.contains(kShellRecorderContext) ||
      !text.contains(kShellRecorderPath)) {
    return false;
  }
  return !text.contains('screen_record');
}

/// 用辅助服务里的录屏写 mp4。时长 0 表示不限，不受系统 `screenrecord` 的 3 分钟检查。
String builtinRecordCommand({
  required String remotePath,
  required int timeLimitSeconds,
}) {
  final limit = timeLimitSeconds <= 0 ? 0 : timeLimitSeconds;
  return 'rm -f ${quoteShell(kBuiltinRecordStopPath)} && '
      'CLASSPATH=$kBuiltinRecorderJar '
      'app_process -Djava.class.path=$kBuiltinRecorderJar /system/bin '
      '$kBuiltinRecorderClass --output ${quoteShell(remotePath)} '
      '--time-limit $limit';
}

String stopBuiltinRecordCommand() =>
    'touch ${quoteShell(kBuiltinRecordStopPath)}';

/// 用临时目录里的程序把 mp4 写到 shell 自己的目录，随后再拉回电脑。
String shellRecorderCommand({
  required String remotePath,
  required int timeLimitSeconds,
  bool allowUnlimited = false,
}) {
  final limit = normalizeScreenrecordLimit(
    timeLimitSeconds,
    allowUnlimited: allowUnlimited,
  );
  return '${quoteShell(kShellRecorderPath)} --time-limit $limit '
      '${quoteShell(remotePath)}';
}

/// 向录屏进程发 SIGINT，让它写完 mp4 再退出。直接关掉 shell 往往只剩残缺文件。
///
/// [processName] 用来避开系统自带的 `screenrecord`。那个进程在受限域里，shell 结束不了它。
String stopScreenrecordCommand([String processName = 'screenrecord']) =>
    'pids=\$(pidof $processName 2>/dev/null || true); '
    'if [ -n "\$pids" ]; then kill -INT \$pids; fi';

String removeRemoteFileCommand(String path) => 'rm -f ${quoteShell(path)}';

bool looksLikePng(List<int> bytes) {
  if (bytes.length < _pngSignature.length) return false;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (bytes[i] != _pngSignature[i]) return false;
  }
  return true;
}

bool looksLikeMp4(List<int> bytes) {
  if (bytes.length < 8) return false;
  return bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70;
}

bool isInsideDirectoryPath(
  String root,
  String target, {
  required String separator,
  bool ignoreCase = false,
}) {
  var rootKey = _stripTrailingSeparator(root, separator);
  var targetKey = _stripTrailingSeparator(target, separator);
  if (ignoreCase) {
    rootKey = rootKey.toLowerCase();
    targetKey = targetKey.toLowerCase();
  }
  return targetKey == rootKey || targetKey.startsWith('$rootKey$separator');
}

String _stripTrailingSeparator(String path, String separator) {
  if (path.length > separator.length && path.endsWith(separator)) {
    return path.substring(0, path.length - separator.length);
  }
  return path;
}
