import 'dart:async';
import 'dart:convert';

import 'package:fire_adb/connection/connection_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../connection/model/connected_device.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../log/app_log.dart';
import 'shell_output.dart';
import 'shell_output_settings.dart';

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
  final ShellOutputBuffer _output = ShellOutputBuffer();
  bool _running = false;
  String? _activeCommand;
  bool _disposing = false;
  StreamSubscription<String>? _streamSubscription;
  ConnectedShell? _currentStream;

  @override
  void initState() {
    super.initState();
    unawaited(_loadOutputLimit());
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
    _output.dispose();
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

  Future<void> _loadOutputLimit() async {
    try {
      final limit = await ShellOutputSettings.loadLimitMiB();
      if (mounted && !_disposing) _output.setLimitMiB(limit);
    } catch (error, stackTrace) {
      log.severe('读取 Shell 输出设置失败', error, stackTrace);
    }
  }

  Future<void> _showOutputSettings() async {
    await ShellOutputSettings.show(
      context,
      currentLimitMiB: _output.limitMiB,
      onSaved: _output.setLimitMiB,
    );
  }

  Future<void> _closeStream(ConnectedShell stream) async {
    try {
      await stream.close();
    } catch (error, stackTrace) {
      log.severe('关闭 Shell 命令流失败：${widget.serial}', error, stackTrace);
    }
  }

  Future<void> _cancelSubscription(
    StreamSubscription<String> subscription,
  ) async {
    try {
      await subscription.cancel();
    } catch (error, stackTrace) {
      log.severe('取消 Shell 命令订阅失败：${widget.serial}', error, stackTrace);
    }
  }

  Future<void> _runCommand() async {
    final cmd = _controller.text.trim();
    if (cmd.isEmpty) return;

    setState(() => _running = true);
    _output.appendLine(ShellOutputType.input, '\$ $cmd');
    _controller.clear();
    _history.insert(0, cmd);
    _historyIndex = -1;
    _textFocusNode.requestFocus();

    final device = _manager.deviceOf(widget.serial);
    if (device == null) {
      if (!mounted) return;
      _output.appendLine(
        ShellOutputType.error,
        context.l10n.shellDeviceNotConnected,
      );
      setState(() => _running = false);
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
      _streamSubscription = const Utf8Decoder(allowMalformed: true)
          .bind(stream.readStream)
          .listen(
            (text) {
              if (!mounted || _disposing) return;
              _output.appendText(ShellOutputType.output, text);
            },
            onDone: () {
              if (!mounted || _disposing) return;
              _finishCommand();
            },
            onError: (Object error, StackTrace stackTrace) {
              log.severe('Shell 命令流失败：$cmd', error, stackTrace);
              if (!mounted || _disposing) return;
              _output.appendLine(
                ShellOutputType.error,
                context.l10n.shellCommandError('$error'),
              );
              _finishCommand();
            },
          );
    } catch (error, stackTrace) {
      log.severe('执行 Shell 命令失败：$cmd', error, stackTrace);
      if (mounted && !_disposing) {
        _output.appendLine(
          ShellOutputType.error,
          context.l10n.shellCommandError('$error'),
        );
      }
      _finishCommand();
    }
  }

  void _finishCommand() {
    _output.flush();
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
      log.severe('向 Shell 发送输入失败：${widget.serial}', error, stackTrace);
      if (mounted && !_disposing) {
        _output.appendLine(
          ShellOutputType.error,
          context.l10n.shellSendInputFailed('$error'),
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
        _running = false;
        _activeCommand = null;
      });
      _output.appendLine(
        ShellOutputType.hint,
        context.l10n.shellCommandAborted,
      );
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
        _output.appendLine(ShellOutputType.hint, '^C');
      }
    } catch (error, stackTrace) {
      log.severe('中断 Shell 命令失败：${widget.serial}', error, stackTrace);
    }
  }

  void _clearOutput() {
    _output.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;

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
                message: l10n.shellClearOutput,
                child: IconButton(
                  icon: const Icon(Icons.clear_all),
                  onPressed: _clearOutput,
                ),
              ),
              Tooltip(
                message: l10n.shellOutputSettings,
                child: IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: _showOutputSettings,
                ),
              ),
              if (_running)
                Tooltip(
                  message: l10n.shellAbortCurrentCommand,
                  child: IconButton(
                    icon: const Icon(Icons.stop, color: Colors.red),
                    onPressed: _abortCommand,
                  ),
                )
              else
                Tooltip(
                  message: l10n.shellSendCtrlC,
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
            child: ShellOutputView(
              output: _output,
              emptyPrompt: l10n.shellEmptyPrompt,
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
                    ? l10n.shellRunningHint
                    : l10n.shellCommandHint,
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
                  ? l10n.shellInteractiveHint
                  : l10n.shellRunningSessionHint,
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
