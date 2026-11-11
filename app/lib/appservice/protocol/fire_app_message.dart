import 'dart:convert';
import 'dart:typed_data';

const int fireAppMessageMaxHeader = 8 * 1024;

/// 发给设备的一条请求。
class FireDataRequest {
  FireDataRequest.none({required String name, required int id})
    : this._(name: name, type: 'none', id: id, body: Uint8List(0));

  FireDataRequest.json({
    required String name,
    required int id,
    required Object body,
  }) : this._(
         name: name,
         type: 'json',
         id: id,
         body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
       );

  FireDataRequest.text({
    required String name,
    required int id,
    required String body,
  }) : this._(
         name: name,
         type: body.isEmpty ? 'none' : 'text',
         id: id,
         body: Uint8List.fromList(utf8.encode(body)),
       );

  FireDataRequest.bytes({
    required String name,
    required int id,
    required List<int> body,
  }) : this._(
         name: name,
         type: 'bytes',
         id: id,
         body: Uint8List.fromList(body),
       );

  FireDataRequest._({
    required this.name,
    required this.type,
    required this.id,
    required this.body,
  });

  final String name;
  final String type;
  final int id;
  final Uint8List body;


  Uint8List get bytes => _encode(name: name, type: type, id: id, body: body);

  String get display => _display(name: name, type: type, id: id, body: body);
}

/// 设备返回的一条响应。推送的请求号是 0，同样是响应。
class FireDataResponse {
  FireDataResponse.none({required String name, required int id})
    : this._(name: name, type: 'none', id: id, body: Uint8List(0));

  FireDataResponse.json({
    required String name,
    required int id,
    required Object body,
  }) : this._(
         name: name,
         type: 'json',
         id: id,
         body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
       );

  FireDataResponse.text({
    required String name,
    required int id,
    required String body,
  }) : this._(
         name: name,
         type: body.isEmpty ? 'none' : 'text',
         id: id,
         body: Uint8List.fromList(utf8.encode(body)),
       );

  FireDataResponse.bytes({
    required String name,
    required int id,
    required List<int> body,
  }) : this._(
         name: name,
         type: 'bytes',
         id: id,
         body: Uint8List.fromList(body),
       );

  FireDataResponse._({
    required this.name,
    required this.type,
    required this.id,
    required this.body,
  });

  final String name;
  final String type;
  final int id;
  final Uint8List body;

  String get text => utf8.decode(body);

  /// 失败说明。正文为空时用 [fallback]。
  String errorText(String fallback) {
    final value = text.trim();
    return value.isEmpty ? fallback : value;
  }

  Map<String, dynamic> get json {
    if (body.isEmpty) return const <String, dynamic>{};
    final value = jsonDecode(text);
    if (value is Map) return Map<String, dynamic>.from(value);
    throw StateError('消息正文不是对象');
  }

  Uint8List get bytes => _encode(name: name, type: type, id: id, body: body);

  String get display => _display(name: name, type: type, id: id, body: body);
}

/// 从陆续到达的字节里取出完整响应。头或正文没凑齐时留到下次。
class FireDataResponseReader {
  final List<int> _pending = <int>[];

  int get pendingBytes => _pending.length;

  List<FireDataResponse> add(List<int> chunk) {
    _pending.addAll(chunk);
    final responses = <FireDataResponse>[];
    while (true) {
      final response = _tryOne();
      if (response == null) return responses;
      responses.add(response);
    }
  }

  FireDataResponse? _tryOne() {
    final colon = _pending.indexOf(0x3a);
    if (colon < 0) {
      if (_pending.length > fireAppMessageMaxHeader) {
        throw StateError('消息头过大');
      }
      return null;
    }
    if (colon + 1 > fireAppMessageMaxHeader) {
      throw StateError('消息头过大');
    }
    final header = ascii.decode(_pending.sublist(0, colon));
    final parts = header.split(' ');
    if (parts.length != 4 || parts.any((part) => part.isEmpty)) {
      throw StateError('消息头无效');
    }
    final id = int.tryParse(parts[2]);
    final length = int.tryParse(parts[3]);
    if (id == null || length == null || length < 0) {
      throw StateError('消息头无效');
    }
    final end = colon + 1 + length;
    if (_pending.length < end) return null;
    final body = Uint8List.fromList(_pending.sublist(colon + 1, end));
    _pending.removeRange(0, end);
    return FireDataResponse._(
      name: parts[0],
      type: parts[1],
      id: id,
      body: body,
    );
  }
}

Uint8List _encode({
  required String name,
  required String type,
  required int id,
  required List<int> body,
}) {
  final header = ascii.encode('$name $type $id ${body.length}:');
  if (header.length > fireAppMessageMaxHeader) {
    throw StateError('消息头过大');
  }
  final bytes = Uint8List(header.length + body.length);
  bytes.setRange(0, header.length, header);
  bytes.setRange(header.length, bytes.length, body);
  return bytes;
}

String _display({
  required String name,
  required String type,
  required int id,
  required List<int> body,
}) {
  final head = '$name $type $id ${body.length}:';
  if (type == 'bytes') return '$head<${body.length} 字节>';
  if (body.isEmpty) return head;
  return '$head${utf8.decode(body)}';
}
