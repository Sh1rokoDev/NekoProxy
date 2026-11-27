import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../app/header_fade.dart';
import '../../app/widgets.dart';
import 'log_text.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  static const _readSize = 256 * 1024;
  static const _tailReadLimit = 2 * 1024 * 1024;
  static const _anchorSize = 64;
  static const _lineLimit = 1500;

  final _scrollController = ScrollController();
  List<String> _lines = [];
  final _partialLine = <int>[];
  List<int> _anchor = const [];
  Timer? _timer;
  Future<void>? _reading;
  int _generation = 0;
  int _offset = 0;
  bool _paused = false;
  bool _clearing = false;
  bool _readFailed = false;
  String _path = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final path = AppScope.of(context).paths.logFile.path;
    if (path != _path) {
      _path = path;
      _generation++;
      _resetTail();
      _readFailed = false;
      _requestRead();
    }
    _timer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _requestRead(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _resetTail() {
    _lines = [];
    _partialLine.clear();
    _anchor = const [];
    _offset = 0;
  }

  void _requestRead() {
    if (_paused || _clearing || _reading != null) return;
    final generation = _generation;
    _reading = _read(_path, generation).whenComplete(() {
      _reading = null;
      if (mounted && generation != _generation) _requestRead();
    });
  }

  bool _canApplyRead(int generation) =>
      mounted && generation == _generation && !_paused && !_clearing;

  Future<(int, List<int>)> _readTail(RandomAccessFile file, int length) async {
    final chunks = <List<int>>[];
    final limit = math.max(0, length - _tailReadLimit);
    var start = length;
    var newlines = 0;
    while (start > limit && newlines <= _lineLimit) {
      final end = start;
      start = math.max(limit, end - _readSize);
      await file.setPosition(start);
      final chunk = await file.read(end - start);
      if (chunk.length != end - start) return (0, const <int>[]);
      chunks.add(chunk);
      newlines += chunk.where((byte) => byte == 0x0A).length;
    }
    final bytes = [for (final chunk in chunks.reversed) ...chunk];
    if (start == 0) return (start, bytes);
    // The tail can begin inside a line or UTF-8 character.
    final firstLine = bytes.indexOf(0x0A);
    final skip = firstLine < 0 ? bytes.length : firstLine + 1;
    return (start + skip, bytes.sublist(skip));
  }

  Future<void> _read(String path, int generation) async {
    try {
      final raf = await File(path).open();
      final offset = _offset;
      final anchor = _anchor;
      List<int> bytes;
      int start;
      bool reset;
      try {
        if (!_canApplyRead(generation)) return;
        final length = await raf.length();
        reset = offset == 0 || length < offset;
        if (!reset && anchor.isNotEmpty) {
          // A new core can replace the file with one that is already longer.
          await raf.setPosition(offset - anchor.length);
          final previous = await raf.read(anchor.length);
          if (previous.length != anchor.length ||
              previous.indexed.any((entry) => entry.$2 != anchor[entry.$1])) {
            reset = true;
          }
        }
        if (reset) {
          (start, bytes) = await _readTail(raf, length);
        } else {
          start = offset;
          await raf.setPosition(start);
          bytes = await raf.read(_readSize);
        }
      } finally {
        await raf.close();
      }
      if (!_canApplyRead(generation)) return;
      if (bytes.isEmpty &&
          start == _offset &&
          !_readFailed &&
          (!reset || _lines.isEmpty)) {
        return;
      }
      final position = _scrollController.hasClients
          ? _scrollController.position
          : null;
      final followOffset =
          position == null || position.maxScrollExtent - position.pixels < 160
          ? position?.pixels ?? 0.0
          : null;
      setState(() {
        if (reset) _resetTail();
        _readFailed = false;
        _offset = start + bytes.length;
        if (bytes.isNotEmpty) {
          _anchor = bytes.length >= _anchorSize
              ? bytes.sublist(bytes.length - _anchorSize)
              : [
                  ..._anchor.skip(
                    math.max(0, _anchor.length + bytes.length - _anchorSize),
                  ),
                  ...bytes,
                ];
          _appendLines(bytes);
        }
      });
      if (followOffset != null) _scrollToEnd(generation, followOffset);
    } on PathNotFoundException {
      if (_canApplyRead(generation) && (_offset != 0 || _readFailed)) {
        setState(() {
          _resetTail();
          _readFailed = false;
        });
      }
    } on FileSystemException {
      if (_canApplyRead(generation) && !_readFailed) {
        setState(() => _readFailed = true);
      }
    }
  }

  void _appendLines(List<int> bytes) {
    final added = <String>[];
    var start = 0;
    for (var index = 0; index < bytes.length; index++) {
      if (bytes[index] != 0x0A) continue;
      _partialLine.addAll(bytes.getRange(start, index));
      if (_partialLine.isNotEmpty && _partialLine.last == 0x0D) {
        _partialLine.removeLast();
      }
      final line = utf8.decode(_partialLine, allowMalformed: true);
      if (line.trim().isNotEmpty) added.add(line);
      _partialLine.clear();
      start = index + 1;
    }
    _partialLine.addAll(bytes.getRange(start, bytes.length));
    if (_partialLine.length > _readSize) {
      _partialLine.removeRange(0, _partialLine.length - _readSize);
    }
    if (added.isEmpty) return;
    final combined = [..._lines, ...added];
    _lines = combined.length > _lineLimit
        ? combined.sublist(combined.length - _lineLimit)
        : combined;
  }

  void _scrollToEnd(int generation, double previousOffset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_canApplyRead(generation) || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (!position.isScrollingNotifier.value &&
          position.pixels == previousOffset) {
        _scrollController.jumpTo(position.maxScrollExtent);
      }
    });
  }

  Future<void> _clearLog() async {
    final path = _path;
    final confirmed = await confirmDialog(
      context,
      title: '清空日志',
      message: '清空当前日志文件？正在运行的核心会在下一次输出时重新写入。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (!confirmed || !mounted || _clearing || path != _path) return;
    setState(() {
      _clearing = true;
      _generation++;
    });
    try {
      await _reading;
      if (!mounted || _path != path) return;
      final file = File(path);
      if (await file.exists()) await file.writeAsString('');
      if (mounted && _path == path) {
        setState(() {
          _resetTail();
          _readFailed = false;
        });
      }
    } on FileSystemException {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法清空日志文件')));
      }
    } finally {
      if (mounted) {
        setState(() => _clearing = false);
        _requestRead();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final theme = Theme.of(context);
    return HeaderScaffold(
      title: const Text('运行日志'),
      maxContentWidth: PageFrame.maxContentWidth,
      actions: [
        HeaderIconButton(
          tooltip: _paused ? '继续' : '暂停',
          onPressed: () {
            setState(() => _paused = !_paused);
            _requestRead();
          },
          icon: _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          active: _paused,
        ),
        HeaderIconButton(
          tooltip: '复制全部',
          onPressed: _lines.isEmpty
              ? null
              : () => copyText(context, _lines.join('\n'), message: '日志已复制'),
          icon: Icons.copy_rounded,
        ),
        HeaderIconButton(
          tooltip: '清空文件',
          onPressed: _lines.isEmpty || _clearing ? null : _clearLog,
          icon: Icons.delete_sweep_outlined,
        ),
      ],
      scrollsBehindHeader: false,
      body: (_) => Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            color: theme.colorScheme.surfaceContainer,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '日志路径：$_path',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_readFailed || !controller.running)
                  Text(
                    _readFailed ? '日志读取失败' : '核心未运行',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
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
                        child: LogText(lines: _lines),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
