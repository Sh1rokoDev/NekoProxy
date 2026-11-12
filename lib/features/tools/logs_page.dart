import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/widgets.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final _scrollController = ScrollController();
  final List<String> _lines = [];
  Timer? _timer;
  int _offset = 0;
  bool _paused = false;
  String _path = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = AppScope.read(context);
    _path = controller.paths.logFile.path;
    _read(reset: true);
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_paused) _read();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _read({bool reset = false}) async {
    if (_paused) return;
    final file = File(_path);
    if (!await file.exists()) return;
    try {
      final length = await file.length();
      if (reset || length < _offset) {
        _offset = 0;
        if (_lines.isNotEmpty) _lines.clear();
      }
      if (length == _offset) return;
      final raf = await file.open();
      try {
        await raf.setPosition(_offset);
        final bytes = await raf.read(length - _offset);
        _offset = length;
        final text = String.fromCharCodes(bytes);
        final newLines = text.split('\n');
        if (newLines.isNotEmpty) {
          setState(() {
            _lines.addAll(newLines.where((line) => line.trim().isNotEmpty));
            if (_lines.length > 1500) {
              _lines.removeRange(0, _lines.length - 1500);
            }
          });
          _scrollToEnd();
        }
      } finally {
        await raf.close();
      }
    } catch (_) {}
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (position.maxScrollExtent - position.pixels < 160 || _paused == false) {
        _scrollController.jumpTo(position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: [
          IconButton(
            tooltip: _paused ? '继续' : '暂停',
            onPressed: () => setState(() => _paused = !_paused),
            icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
          ),
          IconButton(
            tooltip: '复制全部',
            onPressed: _lines.isEmpty ? null : () => copyText(context, _lines.join('\n'), message: '日志已复制'),
            icon: const Icon(Icons.copy_rounded),
          ),
          IconButton(
            tooltip: '清空文件',
            onPressed: _lines.isEmpty
                ? null
                : () async {
                    final confirmed = await confirmDialog(
                      context,
                      title: '清空日志',
                      message: '清空当前日志文件？正在运行的核心会在下一次输出时重新写入。',
                      confirmLabel: '清空',
                      destructive: true,
                    );
                    if (!confirmed) return;
                    try {
                      final file = File(_path);
                      if (await file.exists()) await file.writeAsString('');
                      setState(() => _lines.clear());
                      _offset = 0;
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('清空失败：$e')));
                      }
                    }
                  },
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            color: theme.colorScheme.surfaceContainer,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '日志路径：$_path',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                if (!controller.running)
                  Text('核心未运行', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error)),
              ],
            ),
          ),
          Expanded(
            child: Container(
              color: theme.colorScheme.surfaceContainerLowest,
              padding: const EdgeInsets.all(16),
              child: _lines.isEmpty
                  ? const Center(
                      child: EmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: '暂无日志',
                        message: '启动连接后，核心日志会显示在这里。',
                      ),
                    )
                  : Scrollbar(
                      controller: _scrollController,
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        child: SelectableText(
                          _lines.join('\n'),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            height: 1.55,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
