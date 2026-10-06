import 'dart:async';

/// 按 key 加载并缓存对象。同一个 key 不会并发加载两次。
///
/// 这一批里只要有结果，全部结束后 [onUpdated] 只调用一次。
class ObjectLoader<K, V> {
  ObjectLoader({required this.load, this.onUpdated});

  final Future<V?> Function(K key) load;
  final void Function()? onUpdated;

  final Map<K, V> _cache = <K, V>{};
  final Set<K> _started = <K>{};
  var _inflight = 0;
  var _changed = false;
  var _generation = 0;
  var _disposed = false;

  V? operator [](K key) => _cache[key];

  bool contains(K key) => _cache.containsKey(key);

  /// 已有缓存或正在加载时什么也不做。
  void ensure(K key) {
    if (_disposed || _cache.containsKey(key) || !_started.add(key)) return;
    _inflight++;
    unawaited(_fetch(key, _generation));
  }

  void clear() {
    _generation++;
    _inflight = 0;
    _changed = false;
    _cache.clear();
    _started.clear();
  }

  void dispose() {
    _disposed = true;
    clear();
  }

  Future<void> _fetch(K key, int generation) async {
    try {
      final value = await load(key);
      if (!_disposed && generation == _generation && value != null) {
        _cache[key] = value;
        _changed = true;
      }
    } catch (_) {}
    if (_disposed || generation != _generation) return;
    _inflight--;
    if (_inflight > 0 || !_changed) return;
    _changed = false;
    onUpdated?.call();
  }
}
