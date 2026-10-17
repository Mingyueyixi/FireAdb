import 'package:flutter/material.dart';

import 'data/feature_spec.dart';
import 'device_feature_page.dart';

class _CachedFeature {
  _CachedFeature(this.serial, this.featureId, this.child);

  final String serial;
  final String featureId;
  final Widget child;
}

/// 每个设备和功能各保留一份页面。宽屏面板和窄屏全屏共用这些页面。
class FeatureCache extends StatefulWidget {
  const FeatureCache({
    super.key,
    required this.serials,
    required this.serial,
    required this.featureId,
  });

  final List<String> serials;
  final String serial;
  final String featureId;

  @override
  State<FeatureCache> createState() => _FeatureCacheState();
}

class _FeatureCacheState extends State<FeatureCache> {
  final List<_CachedFeature> _pages = <_CachedFeature>[];

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant FeatureCache oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    // 当前选中设备即使已从已连接表摘掉，也保留页面，方便离线后仍能回看信息。
    final alive = <String>{
      ...widget.serials,
      if (widget.serial.isNotEmpty) widget.serial,
    };
    _pages.removeWhere((page) => !alive.contains(page.serial));
    if (!alive.contains(widget.serial)) return;
    final exists = _pages.any(
      (page) =>
          page.serial == widget.serial && page.featureId == widget.featureId,
    );
    if (exists) return;
    final spec = featureSpecById(widget.featureId);
    _pages.add(
      _CachedFeature(
        widget.serial,
        widget.featureId,
        deviceFeatureBody(
          key: ValueKey<String>('${widget.featureId}@${widget.serial}'),
          serial: widget.serial,
          spec: spec,
        ),
      ),
    );
  }

  bool _isVisible(_CachedFeature page) =>
      page.serial == widget.serial && page.featureId == widget.featureId;

  @override
  Widget build(BuildContext context) {
    if (_pages.isEmpty) return const SizedBox.shrink();
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          for (final page in _pages)
            Offstage(
              offstage: !_isVisible(page),
              child: Focus(
                canRequestFocus: _isVisible(page),
                descendantsAreFocusable: _isVisible(page),
                child: TickerMode(
                  enabled: _isVisible(page),
                  child: page.child,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
