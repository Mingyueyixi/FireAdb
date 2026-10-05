/// 基于字节流的定长异步读取器。
///
/// 包装任意的 `Stream<List<int>>`（如 `Socket`），将粘包/半包数据在内部
/// 重组，对外提供 `readExactly(n)`，是 TCP/USB 传输层的公共基础。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

class _ReadRequest {
  _ReadRequest(this.length, this.completer);

  final int length;
  final Completer<Uint8List> completer;
}

class AdbSizedReader {
  AdbSizedReader(Stream<List<int>> stream) {
    _sub = stream.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    );
  }

  late final StreamSubscription<List<int>> _sub;
  final List<int> _buffer = [];
  final Queue<_ReadRequest> _requests = Queue();
  Object? _error;
  bool _done = false;
  bool _rawMode = false;
  StreamController<List<int>>? _rawController;

  void _onData(List<int> chunk) {
    if (_rawMode) {
      if (chunk.isNotEmpty) _rawController?.add(Uint8List.fromList(chunk));
      return;
    }
    if (chunk.isNotEmpty) {
      _buffer.addAll(chunk);
    }
    _serve();
  }

  void _onError(Object error, StackTrace stack) {
    _error = error;
    if (_rawMode) {
      _rawController?.addError(error, stack);
      unawaited(_rawController?.close());
    }
    _failAll(error, stack);
  }

  void _onDone() {
    _done = true;
    if (_rawMode) {
      unawaited(_rawController?.close());
      return;
    }
    final left = _buffer.length;
    final err = StateError('流已结束，仍有 $left 字节未消费');
    _failAll(err, StackTrace.current);
    _buffer.clear();
  }

  void _failAll(Object error, StackTrace stack) {
    while (_requests.isNotEmpty) {
      final req = _requests.removeFirst();
      req.completer.completeError(error, stack);
    }
  }

  void _serve() {
    while (_requests.isNotEmpty) {
      final req = _requests.first;
      if (_buffer.length < req.length) {
        return;
      }
      final out = Uint8List(req.length);
      for (var i = 0; i < req.length; i++) {
        out[i] = _buffer[i];
      }
      _buffer.removeRange(0, req.length);
      _requests.removeFirst();
      req.completer.complete(out);
    }
  }

  /// 精确读取 [length] 字节，返回新分配的缓冲区。
  Future<Uint8List> readExactly(int length) {
    if (length < 0) {
      throw RangeError.range(length, 0, null, 'length');
    }
    if (length == 0) {
      return Future.value(Uint8List(0));
    }
    if (_error != null) {
      return Future.error(_error!);
    }
    if (_buffer.length >= length) {
      final out = Uint8List.fromList(_buffer.sublist(0, length));
      _buffer.removeRange(0, length);
      return Future.value(out);
    }
    if (_done) {
      return Future.error(StateError('流已结束，无法读取 $length 字节'));
    }
    final req = _ReadRequest(length, Completer<Uint8List>());
    _requests.add(req);
    return req.completer.future;
  }

  /// Transfers all remaining bytes and subsequent chunks as a stream.
  ///
  /// This is used when a framed protocol handshake transitions into an
  /// unframed byte stream without subscribing to the underlying stream twice.
  Stream<List<int>> takeRemainingStream() {
    if (_rawMode) throw StateError('原始字节流已被取出');
    if (_requests.isNotEmpty) {
      throw StateError('仍有未完成的定长读取请求');
    }
    _rawMode = true;
    final controller = StreamController<List<int>>();
    _rawController = controller;
    if (_buffer.isNotEmpty) {
      controller.add(Uint8List.fromList(_buffer));
      _buffer.clear();
    }
    if (_done) unawaited(controller.close());
    if (_error case final error?) {
      controller.addError(error);
      unawaited(controller.close());
    }
    return controller.stream;
  }

  /// 关闭底层订阅并丢弃未完成请求。
  Future<void> close() async {
    await _sub.cancel();
    _failAll(StateError('读取器已关闭'), StackTrace.current);
    if (_rawController case final controller? when !controller.isClosed) {
      await controller.close();
    }
  }
}