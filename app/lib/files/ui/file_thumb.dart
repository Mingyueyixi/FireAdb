import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../appservice/image/fire_app_image.dart';
import '../../connection/connection_manager.dart';
import '../file_entry.dart';

/// 列表里的图片预览。本机直接按目标宽度解码；设备上向常驻辅助服务要小图。
class FileThumb extends StatefulWidget {
  const FileThumb({
    super.key,
    required this.file,
    required this.remote,
    required this.serial,
    required this.fallback,
  });

  final FileEntry file;
  final bool remote;
  final String serial;
  final IconData fallback;

  @override
  State<FileThumb> createState() => _FileThumbState();
}

class _FileThumbState extends State<FileThumb> {
  Uint8List? _bytes;
  var _generation = 0;
  var _showLocal = false;
  bool? _ticking;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (_ticking == active) return;
    final wasHidden = _ticking == false;
    _ticking = active;
    if (!active) {
      _generation++;
      return;
    }
    if (wasHidden) _schedule();
  }

  @override
  void didUpdateWidget(FileThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path ||
        oldWidget.file.size != widget.file.size ||
        oldWidget.serial != widget.serial ||
        oldWidget.remote != widget.remote) {
      _bytes = null;
      _showLocal = false;
      _schedule();
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  /// 先让目录列表画出来，再读缓存或向设备要小图。
  void _schedule() {
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      if (!TickerMode.valuesOf(context).enabled) return;
      unawaited(_load(generation));
    });
  }

  Future<void> _load(int generation) async {
    if (!_canPreview(widget.file)) return;
    if (!widget.remote) {
      if (!mounted || generation != _generation) return;
      setState(() => _showLocal = true);
      return;
    }
    final key = imageThumbKey(
      serial: widget.serial,
      path: widget.file.path,
      size: widget.file.size,
    );
    final cached = await readImageThumbCache(key);
    if (!mounted || generation != _generation) return;
    if (cached != null) {
      setState(() => _bytes = cached);
      return;
    }
    if (imageThumbFailed(key)) return;
    final device = Get.find<ConnectionManager>().deviceOf(widget.serial);
    if (device == null) return;
    final bytes = await requestImageThumb(
      device: device,
      path: widget.file.path,
      key: key,
      cancelled: () => !mounted || generation != _generation,
    );
    if (!mounted || generation != _generation) return;
    if (bytes == null || bytes.isEmpty) return;
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    return _frame(
      Stack(
        fit: StackFit.expand,
        children: [
          Center(child: Icon(widget.fallback)),
          if (_bytes != null)
            Image.memory(
              _bytes!,
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.low,
              frameBuilder: _whenDecoded,
              errorBuilder: (context, error, stackTrace) =>
                  const SizedBox.shrink(),
            ),
          if (_showLocal)
            Image.file(
              File(widget.file.path),
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              cacheWidth: 80,
              filterQuality: FilterQuality.low,
              frameBuilder: _whenDecoded,
              errorBuilder: (context, error, stackTrace) =>
                  const SizedBox.shrink(),
            ),
        ],
      ),
    );
  }

  Widget _whenDecoded(
    BuildContext context,
    Widget child,
    int? frame,
    bool wasSynchronouslyLoaded,
  ) {
    if (frame == null) return const SizedBox.shrink();
    return child;
  }

  Widget _frame(Widget child) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(width: 40, height: 40, child: child),
    );
  }
}

bool _canPreview(FileEntry file) {
  if (file.canEnter || file.isLink) return false;
  if (file.sizeKnown && file.size > imageThumbMaxBytes) return false;
  return isPreviewImageName(file.name);
}
