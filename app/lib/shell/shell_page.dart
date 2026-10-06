import 'dart:async';
import 'dart:convert';

import 'package:fire_adb/connection/connection_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../app_feedback.dart';
import '../connection/model/connected_device.dart';

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
  String? _activeCommand;
  bool _disposing = false;
  StreamSubscription<String>? _streamSubscription;
  ConnectedShell? _currentStream;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_disposing) {
        _keyFocusNode.requestFocus();
        _textFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _disposing = true;
    final subscription = _streamSubscription;
    _streamSubscription = null;
    if (subscription != null) unawaited(_cancelSubscription(subscription));
    final stream = _currentStream;
    _currentStream = null;
    if (stream != null) unawaited(_closeStream(stream));
    _controller.dispose();
    _textFocusNode.dispose();
    _keyFocusNode.dispose();
    super.dispose();
  }

  Future<void> _closeStream(ConnectedShell stream) async {
    try {
      await stream.close();
    } catch (error, stackTrace) {
      logAppError('关闭 Shell 命令流失败：${widget.serial}', error, stackTrace);
    }
  }

  Future<void> _cancelSubscription(
    StreamSubscription<String> subscription,
  ) async {
    try {
      await subscription.cancel();
    } catch (error, stackTrace) {
      logAppError('取消 Shell 命令订阅失败：${widget.serial}', error, stackTrace);
    }
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
      final stream = await device.openShell(cmd);
      if (!mounted || _disposing) {
        await _closeStream(stream);
        return;
      }
      setState(() {
        _currentStream = stream;
        _activeCommand = cmd;
      });
      final buffer = StringBuffer();
      _streamSubscription = const Utf8Decoder(allowMalformed: true)
          .bind(stream.readStream)
          .listen(
            (text) {
              if (!mounted || _disposing) return;
              buffer.write(text);
              final lines = buffer.toString().split('\n');
              buffer.clear();
              buffer.write(lines.last);
              for (var i = 0; i < lines.length - 1; i++) {
                if (lines[i].isNotEmpty) {
                  if (mounted && !_disposing) {
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
              if (!mounted || _disposing) return;
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
            onError: (Object error, StackTrace stackTrace) {
              logAppError('Shell 命令流失败：$cmd', error, stackTrace);
              if (!mounted || _disposing) return;
              setState(
                () => _output.add(
                  _OutputLine(type: _OutputType.error, text: '错误: $error'),
                ),
              );
              _finishCommand();
            },
          );
    } catch (error, stackTrace) {
      logAppError('执行 Shell 命令失败：$cmd', error, stackTrace);
      if (mounted && !_disposing) {
        setState(
          () => _output.add(
            _OutputLine(type: _OutputType.error, text: '错误: $error'),
          ),
        );
      }
      _finishCommand();
    }
  }

  void _finishCommand() {
    final subscription = _streamSubscription;
    _streamSubscription = null;
    if (subscription != null) unawaited(_cancelSubscription(subscription));
    final stream = _currentStream;
    _currentStream = null;
    if (stream != null) unawaited(_closeStream(stream));
    if (mounted && !_disposing) {
      setState(() {
        _running = false;
        _activeCommand = null;
      });
    }
  }

  bool _isInteractiveShellCommand(String? command) {
    if (command == null) return false;
    final parts = command.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return false;

    var executableIndex = 0;
    var executable = parts[executableIndex].split('/').last;
    if ((executable == 'busybox' || executable == 'toybox') &&
        parts.length > 1) {
      executable = parts[++executableIndex].split('/').last;
    }

    const shellExecutables = <String>{
      'su',
      'sh',
      'ash',
      'bash',
      'dash',
      'ksh',
      'mksh',
      'zsh',
    };
    if (!shellExecutables.contains(executable)) return false;

    return !parts
        .skip(executableIndex + 1)
        .any(
          (part) =>
              part == '-c' ||
              part == '--command' ||
              part.startsWith('--command='),
        );
  }

  void _submitInput() {
    if (_running) {
      unawaited(_sendInput());
    } else {
      unawaited(_runCommand());
    }
  }

  Future<void> _sendInput() async {
    final stream = _currentStream;
    if (stream == null) return;

    final input = _controller.text;
    _controller.clear();
    try {
      await stream.write(utf8.encode('$input\n'));
    } catch (error, stackTrace) {
      logAppError('向 Shell 发送输入失败：${widget.serial}', error, stackTrace);
      if (mounted && !_disposing) {
        setState(
          () => _output.add(
            _OutputLine(type: _OutputType.error, text: '发送输入失败: $error'),
          ),
        );
      }
      _finishCommand();
    }
  }

  void _abortCommand() {
    final subscription = _streamSubscription;
    _streamSubscription = null;
    if (subscription != null) unawaited(_cancelSubscription(subscription));
    final stream = _currentStream;
    _currentStream = null;
    if (stream != null) unawaited(_closeStream(stream));
    if (mounted && !_disposing) {
      setState(() {
        _output.add(_OutputLine(type: _OutputType.hint, text: '^C (已中止)'));
        _running = false;
        _activeCommand = null;
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
    final stream = _currentStream;
    if (stream == null) return;
    try {
      await stream.write(const <int>[3]);
      if (mounted) {
        setState(
          () => _output.add(_OutputLine(type: _OutputType.hint, text: '^C')),
        );
      }
    } catch (error, stackTrace) {
      logAppError('中断 Shell 命令失败：${widget.serial}', error, stackTrace);
    }
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
                      '运行中可输入内容并回车发送；点击停止按钮中止\n'
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
              decoration: InputDecoration(
                hintText: _running
                    ? '向当前 Shell 输入内容并回车发送'
                    : '输入命令 (如: ls -la /sdcard)',
                hintStyle: TextStyle(fontFamily: 'monospace'),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: (_) => _submitInput(),
              textInputAction: TextInputAction.send,
            ),
          ),
        ),
        if (_running && _currentStream != null)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              _isInteractiveShellCommand(_activeCommand)
                  ? '交互式 Shell · 输入 exit 结束'
                  : '会话运行中 · 输入发送给当前进程',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.secondary,
              ),
            ),
          )
        else if (_running)
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
