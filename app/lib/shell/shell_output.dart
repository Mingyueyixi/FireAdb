import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../l10n/fire_adb_localizations_ext.dart';

enum ShellOutputType { input, output, error, hint }

class ShellOutputSegment {
  const ShellOutputSegment({required this.type, required this.text});

  final ShellOutputType type;
  final String text;
}

class ShellOutputBuffer extends ChangeNotifier {
  static const int defaultLimitMiB = 10;
  static const int _bytesPerMiB = 1024 * 1024;
  static const int _chunkCharacters = 4096;
  static const Duration _flushInterval = Duration(milliseconds: 200);

  final List<ShellOutputSegment> _segments = <ShellOutputSegment>[];
  final List<ShellOutputSegment> _pending = <ShellOutputSegment>[];
  Timer? _flushTimer;
  int _maxCharacters = defaultLimitMiB * _bytesPerMiB;
  int _characterCount = 0;
  bool _truncated = false;

  List<ShellOutputSegment> get segments =>
      UnmodifiableListView<ShellOutputSegment>(_segments);
  bool get truncated => _truncated;
  int get limitMiB => _maxCharacters ~/ _bytesPerMiB;

  void appendLine(ShellOutputType type, String text) {
    appendText(type, '$text\n');
  }

  void appendText(ShellOutputType type, String text) {
    if (text.isEmpty) return;
    var offset = 0;
    while (offset < text.length) {
      var end = (offset + _chunkCharacters).clamp(0, text.length);
      if (end < text.length &&
          _isHighSurrogate(text.codeUnitAt(end - 1)) &&
          _isLowSurrogate(text.codeUnitAt(end))) {
        end--;
      }
      final piece = text.substring(offset, end);
      final last = _pending.isEmpty ? null : _pending.last;
      if (last != null &&
          last.type == type &&
          last.text.length + piece.length <= _chunkCharacters) {
        _pending[_pending.length - 1] = ShellOutputSegment(
          type: type,
          text: '${last.text}$piece',
        );
      } else {
        _pending.add(ShellOutputSegment(type: type, text: piece));
      }
      offset = end;
    }
    _flushTimer ??= Timer(_flushInterval, flush);
  }

  void flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pending.isEmpty) return;
    _segments.addAll(_pending);
    _characterCount += _pending.fold<int>(
      0,
      (total, segment) => total + segment.text.length,
    );
    _pending.clear();
    _trimToLimit();
    notifyListeners();
  }

  void setLimitMiB(int limitMiB) {
    if (_maxCharacters == limitMiB * _bytesPerMiB) return;
    flush();
    _maxCharacters = limitMiB * _bytesPerMiB;
    _trimToLimit();
    notifyListeners();
  }

  void clear() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();
    _segments.clear();
    _characterCount = 0;
    _truncated = false;
    notifyListeners();
  }

  void _trimToLimit() {
    if (_characterCount <= _maxCharacters || _segments.isEmpty) return;

    final excess = _characterCount - _maxCharacters;
    var removeCount = 0;
    var removedCharacters = 0;
    while (removeCount < _segments.length &&
        removedCharacters + _segments[removeCount].text.length <= excess) {
      removedCharacters += _segments[removeCount].text.length;
      removeCount++;
    }

    var partialOffset = 0;
    if (removedCharacters < excess && removeCount < _segments.length) {
      final oldest = _segments[removeCount];
      partialOffset = excess - removedCharacters;
      if (partialOffset < oldest.text.length &&
          _isLowSurrogate(oldest.text.codeUnitAt(partialOffset)) &&
          _isHighSurrogate(oldest.text.codeUnitAt(partialOffset - 1))) {
        partialOffset++;
      }
      removedCharacters += partialOffset;
    }

    if (removeCount > 0) _segments.removeRange(0, removeCount);
    if (partialOffset > 0 && _segments.isNotEmpty) {
      final oldest = _segments[0];
      _segments[0] = ShellOutputSegment(
        type: oldest.type,
        text: oldest.text.substring(partialOffset),
      );
    }
    _characterCount -= removedCharacters;
    _truncated = true;
  }

  bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  @override
  void dispose() {
    _flushTimer?.cancel();
    _pending.clear();
    super.dispose();
  }
}

class ShellOutputView extends StatefulWidget {
  const ShellOutputView({
    super.key,
    required this.output,
    required this.emptyPrompt,
  });

  final ShellOutputBuffer output;
  final String emptyPrompt;

  @override
  State<ShellOutputView> createState() => _ShellOutputViewState();
}

class _ShellOutputViewState extends State<ShellOutputView> {
  final ScrollController _scrollController = ScrollController();
  bool _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    widget.output.addListener(_onOutputChanged);
  }

  @override
  void didUpdateWidget(covariant ShellOutputView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.output == widget.output) return;
    oldWidget.output.removeListener(_onOutputChanged);
    widget.output.addListener(_onOutputChanged);
  }

  @override
  void dispose() {
    widget.output.removeListener(_onOutputChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onOutputChanged() {
    if (!mounted) return;
    setState(() {});
    if (!_stickToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  TextStyle _styleFor(ShellOutputType type, ThemeData theme) {
    final scheme = theme.colorScheme;
    final baseStyle = theme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
    );
    return switch (type) {
      ShellOutputType.input =>
        baseStyle?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.bold,
            ) ??
            const TextStyle(),
      ShellOutputType.error =>
        baseStyle?.copyWith(color: scheme.error) ?? const TextStyle(),
      ShellOutputType.hint =>
        baseStyle?.copyWith(
              color: scheme.outline,
              fontStyle: FontStyle.italic,
            ) ??
            const TextStyle(),
      ShellOutputType.output =>
        baseStyle?.copyWith(color: scheme.onSurface) ?? const TextStyle(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segments = widget.output.segments;
    if (segments.isEmpty && !widget.output.truncated) {
      return Center(
        child: Text(
          widget.emptyPrompt,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification ||
            notification is ScrollEndNotification) {
          _stickToBottom =
              notification.metrics.maxScrollExtent -
                  notification.metrics.pixels <=
              32;
        }
        return false;
      },
      child: SelectionArea(
        child: ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(12),
          itemCount: segments.length + (widget.output.truncated ? 1 : 0),
          itemBuilder: (context, index) {
            if (widget.output.truncated && index == 0) {
              return Text(
                context.l10n.shellEarlierOutputOmitted,
                style: _styleFor(ShellOutputType.hint, theme),
              );
            }
            final segment = segments[index - (widget.output.truncated ? 1 : 0)];
            return Text(segment.text, style: _styleFor(segment.type, theme));
          },
        ),
      ),
    );
  }
}
