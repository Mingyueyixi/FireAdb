import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../connection/model/connected_device.dart';
import '../../link/device_link.dart';
import '../../log/app_log.dart';
import '../protocol/fire_app_message.dart';

const int imageThumbMaxBytes = 32 * 1024 * 1024;

/// 常见图片后缀。和设备端 {@code ImageThumbProtocol} 保持同一份。
bool isPreviewImageName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot >= name.length - 1) return false;
  switch (name.substring(dot + 1).toLowerCase()) {
    case 'jpg':
    case 'jpeg':
    case 'png':
    case 'webp':
    case 'gif':
    case 'bmp':
    case 'heic':
    case 'heif':
      return true;
    default:
      return false;
  }
}

/// 同一台设备上，路径和文件长度没变就用同一张本地小图。
/// 路径里已经包含文件名。文件名用这段内容的 MD5，避免路径字符不合法。
String imageThumbKey({
  required String serial,
  required String path,
  required int size,
}) => '$serial\n$path\n$size';

Uint8List? cachedImageThumb(String key) => _thumbs[key];

/// 内存或本地文件里已经有的小图。不访问设备。
Future<Uint8List?> readImageThumbCache(String key) async {
  final memory = _thumbs[key];
  if (memory != null) return memory;
  final saved = await _readThumb(key);
  if (saved == null || saved.isEmpty) return null;
  _remember(key, saved);
  return saved;
}

bool imageThumbFailed(String key) => _failed.contains(key);

/// 向设备上已经在听的辅助服务要一张小图。同一台设备上的请求串行发出，
/// 并复用已经握过手的连接。
/// [cancel] 在还没发出时生效；已经发出的会完成，但不再写入缓存。
Future<Uint8List?> requestImageThumb({
  required ConnectedDevice device,
  required String path,
  required String key,
  required bool Function() cancelled,
}) {
  final cached = _thumbs[key];
  if (cached != null) return Future<Uint8List?>.value(cached);
  if (_failed.contains(key)) return Future<Uint8List?>.value(null);
  final pending = _inflight[key];
  if (pending != null) return pending;
  final job = _ThumbJob(device, path, key, cancelled);
  _inflight[key] = job.done.future;
  _queue.add(job);
  _pump();
  return job.done.future;
}

final _thumbs = <String, Uint8List>{};
final _order = <String>[];
final _failed = <String>{};
final _inflight = <String, Future<Uint8List?>>{};
final _queue = <_ThumbJob>[];
var _pumping = false;
_ThumbPipe? _pipe;

const int _cacheLimit = 80;

class _ThumbJob {
  _ThumbJob(this.device, this.path, this.key, this.cancelled);

  final ConnectedDevice device;
  final String path;
  final String key;
  final bool Function() cancelled;
  final done = Completer<Uint8List?>();
}

void _pump() {
  if (_pumping) return;
  _pumping = true;
  unawaited(_drain());
}

Future<void> _drain() async {
  try {
    while (_queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      if (job.cancelled()) {
        _inflight.remove(job.key);
        if (!job.done.isCompleted) job.done.complete(null);
        continue;
      }
      _ThumbBytes? loaded;
      try {
        loaded = await _load(job);
      } catch (error, stackTrace) {
        log.warning('图片预览失败：${job.path}', error, stackTrace);
      } finally {
        _inflight.remove(job.key);
      }
      final bytes = loaded?.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        _store(job.key, bytes);
      } else if (loaded != null && loaded.reject && !job.cancelled()) {
        _failed.add(job.key);
      }
      if (!job.done.isCompleted) job.done.complete(bytes);
    }
  } finally {
    _pumping = false;
    if (_queue.isNotEmpty) _pump();
  }
}

class _ThumbBytes {
  const _ThumbBytes(this.bytes, {required this.reject});

  final Uint8List? bytes;

  /// 服务明确拒绝这张图时不再重试。连不上服务时为 false。
  final bool reject;
}

class _ThumbPipe {
  _ThumbPipe(this.serial, this.shell, this.input);

  final String serial;
  final ConnectedShell shell;
  final StreamIterator<List<int>> input;
  final reader = FireDataResponseReader();
  final frames = <FireDataResponse>[];

  Future<void> close() async {
    try {
      await input.cancel();
    } catch (_) {}
    try {
      await shell.close();
    } catch (_) {}
  }
}

Future<_ThumbBytes> _load(_ThumbJob job) async {
  final saved = await _readThumb(job.key);
  if (saved != null) {
    _remember(job.key, saved);
    return _ThumbBytes(saved, reject: false);
  }
  if (job.cancelled()) return const _ThumbBytes(null, reject: false);
  log.info('图片预览排队 ${job.device.serial} ${job.path}');
  try {
    return await _request(job);
  } catch (error, stackTrace) {
    log.warning('图片预览失败：${job.path}', error, stackTrace);
    await _dropPipe();
    return const _ThumbBytes(null, reject: false);
  }
}

Future<_ThumbBytes> _request(_ThumbJob job) async {
  final pipe = await _open(job.device);
  if (job.cancelled()) return const _ThumbBytes(null, reject: false);
  await pipe.shell.write(
    FireDataRequest.json(
      name: 'image.thumb',
      id: 1,
      body: <String, String>{'path': job.path},
    ).bytes,
  );
  final message = await _frame(pipe, const Duration(seconds: 8));
  if (message.name == 'session.error') {
    final text = message.errorText('无法生成预览');
    log.warning('图片预览失败：${job.path} $text');
    return _ThumbBytes(null, reject: _permanent(text));
  }
  if (message.name != 'image.thumb' || message.type != 'bytes') {
    throw StateError('图片预览响应无效');
  }
  if (message.body.isEmpty) return const _ThumbBytes(null, reject: true);
  return _ThumbBytes(message.body, reject: false);
}

Future<_ThumbPipe> _open(ConnectedDevice device) async {
  final current = _pipe;
  if (current != null && current.serial == device.serial) return current;
  await _dropPipe();
  try {
    return await _connect(device);
  } catch (error, stackTrace) {
    log.warning('图片预览没有连上应用服务 ${device.serial}', error, stackTrace);
    await _dropPipe();
    rethrow;
  }
}

Future<_ThumbPipe> _connect(ConnectedDevice device) async {
  final opened = device.openService('tcp:$deviceServicePort');
  final ConnectedShell shell;
  try {
    shell = await opened.timeout(const Duration(milliseconds: 800));
  } catch (error) {
    unawaited(
      opened.then<void>(
        (shell) => shell.close(),
        onError: (Object _) {},
      ),
    );
    rethrow;
  }
  final pipe = _ThumbPipe(
    device.serial,
    shell,
    StreamIterator<List<int>>(shell.readStream),
  );
  try {
    final hello = await _frame(pipe, const Duration(seconds: 2));
    if (hello.name != 'session.hello' && hello.name != 'session.ready') {
      throw StateError('应用信息服务没有就绪');
    }
    if (hello.name != 'session.ready') {
      final ready = await _frame(pipe, const Duration(seconds: 2));
      if (ready.name != 'session.ready') {
        throw StateError('应用信息服务没有就绪');
      }
    }
  } catch (error) {
    await pipe.close();
    rethrow;
  }
  _pipe = pipe;
  return pipe;
}

Future<void> _dropPipe() async {
  final pipe = _pipe;
  _pipe = null;
  await pipe?.close();
}

bool _permanent(String text) {
  return text.contains('不是图片') ||
      text.contains('无法识别') ||
      text.contains('图片过大') ||
      text.contains('文件不存在') ||
      text.contains('路径无效');
}

Future<FireDataResponse> _frame(_ThumbPipe pipe, Duration limit) async {
  while (pipe.frames.isEmpty) {
    final arrived = await pipe.input.moveNext().timeout(limit);
    if (!arrived) throw StateError('应用信息服务已断开');
    pipe.frames.addAll(pipe.reader.add(pipe.input.current));
  }
  return pipe.frames.removeAt(0);
}

void _remember(String key, Uint8List bytes) {
  _failed.remove(key);
  if (_thumbs.containsKey(key)) {
    _order.remove(key);
  }
  _thumbs[key] = bytes;
  _order.add(key);
  while (_order.length > _cacheLimit) {
    final oldest = _order.removeAt(0);
    _thumbs.remove(oldest);
  }
}

void _store(String key, Uint8List bytes) {
  _remember(key, bytes);
  unawaited(_writeThumb(key, bytes));
}

String _thumbDigest(String key) => md5.convert(utf8.encode(key)).toString();

Future<Directory>? _thumbDirFuture;

Future<Directory> _thumbDirectory() {
  return _thumbDirFuture ??= () async {
    if (!Platform.isAndroid) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dir = Directory(p.join(await getDatabasesPath(), 'image-thumbs'));
    await dir.create(recursive: true);
    return dir;
  }();
}

Future<Uint8List?> _readThumb(String key) async {
  try {
    final dir = await _thumbDirectory();
    final file = File(p.join(dir.path, '${_thumbDigest(key)}.jpg'));
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return bytes;
  } catch (error, stackTrace) {
    log.warning('图片预览没有读到本地缓存', error, stackTrace);
    return null;
  }
}

Future<void> _writeThumb(String key, Uint8List bytes) async {
  try {
    final dir = await _thumbDirectory();
    final file = File(p.join(dir.path, '${_thumbDigest(key)}.jpg'));
    await file.writeAsBytes(bytes, flush: true);
    _thumbWrites++;
    if (_thumbWrites == 1 || _thumbWrites % 40 == 0) {
      await _trimThumbs(dir);
    }
  } catch (error, stackTrace) {
    log.warning('图片预览没有写入本地缓存', error, stackTrace);
  }
}

const int _diskKeep = 400;
const int _diskLimit = 500;
var _thumbWrites = 0;

Future<void> _trimThumbs(Directory dir) async {
  final files = <File>[];
  await for (final entity in dir.list()) {
    if (entity is File) files.add(entity);
  }
  if (files.length <= _diskLimit) return;
  final stamped = <({File file, DateTime modified})>[];
  for (final file in files) {
    stamped.add((file: file, modified: await file.lastModified()));
  }
  stamped.sort((a, b) => a.modified.compareTo(b.modified));
  final extra = stamped.length - _diskKeep;
  for (var index = 0; index < extra; index++) {
    try {
      await stamped[index].file.delete();
    } catch (_) {}
  }
}
