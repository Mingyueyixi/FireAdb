import 'dart:async';

import 'package:adb_core/adb_core.dart';
import 'package:fire_adb/connection/connection_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// 交互式 Shell 命令面板。
class ShellPage extends StatefulWidget {
  const ShellPage({super.key, required this.serial});

  final String serial;

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  ConnectionManager get _manager => Get.find<ConnectionManager>();

  final TextEditingController _controller = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  final FocusNode _keyFocusNode = FocusNode();
  final List<String> _history = <String>[];
  int _historyIndex = -1;
  final List<_OutputLine> _output = <_OutputLine>[];
  bool _running = false;
  StreamSubscription<Uint8List>? _streamSubscription;
  AdbStream? _currentStream;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _keyFocusNode.requestFocus();
        _textFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _textFocusNode.dispose();
    _keyFocusNode.dispose();
    _abortCommand();
    super.dispose();
  }

  Future<void> _runCommand() async {
    final cmd = _controller.text.trim();
    if (cmd.isEmpty) return;

    setState(() {
      _output.add(_OutputLine(type: _OutputType.input, text: '\$ $cmd'));
      _running = true;
    });
    _controller.clear();
    _history.insert(0, cmd);
    _historyIndex = -1;
    _textFocusNode.requestFocus();

    final device = _manager.deviceOf(widget.serial);
    if (device == null) {
      if (!mounted) return;
      setState(() {
        _output.add(_OutputLine(type: _OutputType.error, text: '设备未连接'));
        _running = false;
      });
      return;
    }

    try {
      final stream = await device.connection.open('shell:$cmd');
      _currentStream = stream;
      final buffer = StringBuffer();
      _streamSubscription = stream.readStream().listen(
        (chunk) {
          if (!mounted) return;
          final text = String.fromCharCodes(chunk);
          buffer.write(text);
          final lines = buffer.toString().split('\n');
          buffer.clear();
          buffer.write(lines.last);
          for (var i = 0; i < lines.length - 1; i++) {
            if (lines[i].isNotEmpty) {
              if (mounted) {
                setState(
                  () => _output.add(
                    _OutputLine(type: _OutputType.output, text: lines[i]),
                  ),
                );
              }
            }
          }
        },
        onDone: () {
          if (!mounted) return;
          final remaining = buffer.toString();
          if (remaining.isNotEmpty) {
            setState(
              () => _output.add(
                _OutputLine(type: _OutputType.output, text: remaining),
              ),
            );
          }
          _finishCommand();
        },
        onError: (e) {
          if (!mounted) return;
          setState(
            () => _output.add(
              _OutputLine(type: _OutputType.error, text: '错误: $e'),
            ),
          );
          _finishCommand();
        },
      );
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _output.add(_OutputLine(type: _OutputType.error, text: '错误: $e')),
        );
      }
      _finishCommand();
    }
  }

  void _finishCommand() {
    _streamSubscription?.cancel();
    _streamSubscription = null;
    _currentStream = null;
    if (mounted) {
      setState(() => _running = false);
    }
  }

  void _abortCommand() {
    _streamSubscription?.cancel();
    _streamSubscription = null;
    _currentStream?.close();
    _currentStream = null;
    if (mounted) {
      setState(() {
        _output.add(_OutputLine(type: _OutputType.hint, text: '^C (已中止)'));
        _running = false;
      });
    }
  }

  KeyEventResult _onKeyPress(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (_historyIndex < _history.length - 1) {
          _historyIndex++;
          _controller.text = _history[_historyIndex];
          _controller.selection = TextSelection.fromPosition(
            TextPosition(offset: _controller.text.length),
          );
        }
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        if (_historyIndex > 0) {
          _historyIndex--;
          _controller.text = _history[_historyIndex];
          _controller.selection = TextSelection.fromPosition(
            TextPosition(offset: _controller.text.length),
          );
        } else if (_historyIndex == 0) {
          _historyIndex = -1;
          _controller.clear();
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Future<void> _sendCtrlC() async {
    final device = _manager.deviceOf(widget.serial);
    if (device == null) return;
    try {
      await device.shell('\x03');
      if (mounted) {
        setState(
          () => _output.add(_OutputLine(type: _OutputType.hint, text: '^C')),
        );
      }
    } catch (_) {}
  }

  void _clearOutput() {
    setState(() => _output.clear());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      children: <Widget>[
        // 工具栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.terminal, color: scheme.primary),
              const SizedBox(width: 8),
              Text('Shell', style: theme.textTheme.titleMedium),
              const Spacer(),
              Tooltip(
                message: '清空输出',
                child: IconButton(
                  icon: const Icon(Icons.clear_all),
                  onPressed: _clearOutput,
                ),
              ),
              if (_running)
                Tooltip(
                  message: '中止当前命令',
                  child: IconButton(
                    icon: const Icon(Icons.stop, color: Colors.red),
                    onPressed: _abortCommand,
                  ),
                )
              else
                Tooltip(
                  message: '发送 Ctrl+C',
                  child: IconButton(
                    icon: const Icon(Icons.stop_circle),
                    onPressed: _sendCtrlC,
                  ),
                ),
            ],
          ),
        ),
        // 输出区域
        Expanded(
          child: Container(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
            child: _output.isEmpty
                ? Center(
                    child: Text(
                      '输入命令并按回车执行\n'
                      '↑/↓ 浏览历史\n'
                      '运行中点击停止按钮中止\n'
                      '常用: ls, ps, logcat, dumpsys, top, df',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: _output.length,
                    itemBuilder: (context, index) {
                      final line = _output[_output.length - 1 - index];
                      return SelectableText.rich(
                        TextSpan(
                          children: <TextSpan>[
                            if (line.type == _OutputType.input)
                              TextSpan(
                                text: line.text,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontFamily: 'monospace',
                                  color: scheme.primary,
                                  fontWeight: FontWeight.bold,
                                ),
                              )
                            else if (line.type == _OutputType.error)
                              TextSpan(
                                text: line.text,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontFamily: 'monospace',
                                  color: scheme.error,
                                ),
                              )
                            else if (line.type == _OutputType.hint)
                              TextSpan(
                                text: line.text,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontFamily: 'monospace',
                                  color: scheme.outline,
                                  fontStyle: FontStyle.italic,
                                ),
                              )
                            else
                              TextSpan(
                                text: line.text,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontFamily: 'monospace',
                                  color: scheme.onSurface,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
        // 输入行
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Focus(
            focusNode: _keyFocusNode,
            onKeyEvent: _onKeyPress,
            autofocus: true,
            child: TextField(
              controller: _controller,
              focusNode: _textFocusNode,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
              ),
              decoration: const InputDecoration(
                hintText: '输入命令 (如: ls -la /sdcard)',
                hintStyle: TextStyle(fontFamily: 'monospace'),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: (_) => _running ? null : _runCommand(),
              textInputAction: TextInputAction.send,
            ),
          ),
        ),
        if (_running)
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }
}

enum _OutputType { input, output, error, hint }

class _OutputLine {
  _OutputLine({required this.type, required this.text});
  final _OutputType type;
  final String text;
}
