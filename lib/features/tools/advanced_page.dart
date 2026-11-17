import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/header_fade.dart';
import '../../app/widgets.dart';
import '../../state/app_controller.dart';

class AdvancedPage extends StatefulWidget {
  const AdvancedPage({super.key});

  @override
  State<AdvancedPage> createState() => _AdvancedPageState();
}

class _AdvancedPageState extends State<AdvancedPage> {
  late final TextEditingController _url;
  late final TextEditingController _interval;
  late final TextEditingController _tolerance;
  late final TextEditingController _idle;
  String _logLevel = 'info';
  bool _interrupt = false;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final advanced = AppScope.read(context).settings.advancedOrDefault;
    _url = TextEditingController(text: advanced.urlTestUrl);
    _interval = TextEditingController(text: advanced.urlTestInterval);
    _tolerance = TextEditingController(text: '${advanced.urlTestTolerance}');
    _idle = TextEditingController(text: advanced.urlTestIdleTimeout);
    _logLevel = advanced.logLevel;
    _interrupt = advanced.interruptExistingConnections;
  }

  @override
  void dispose() {
    _url.dispose();
    _interval.dispose();
    _tolerance.dispose();
    _idle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    return HeaderScaffold(
      title: const Text('运行参数'),
      body: (headerInset) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, headerInset + 24, 24, 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: HeaderScaffold.defaultContentWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionCard(
                  title: '自动选择（sing-box urltest）',
                  icon: Icons.speed_rounded,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _url,
                        decoration: const InputDecoration(labelText: '测速 URL'),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _interval,
                              decoration: const InputDecoration(
                                labelText: '间隔',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: _idle,
                              decoration: const InputDecoration(
                                labelText: '空闲超时',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _tolerance,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '容差（毫秒）'),
                      ),
                      SwitchRow(
                        title: '切换时中断现有入站连接',
                        value: _interrupt,
                        onChanged: (value) =>
                            setState(() => _interrupt = value),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: '日志',
                  icon: Icons.receipt_long_outlined,
                  child: DropdownButtonFormField<String>(
                    initialValue: _logLevel,
                    decoration: const InputDecoration(labelText: '日志级别'),
                    items: const [
                      DropdownMenuItem(value: 'trace', child: Text('trace')),
                      DropdownMenuItem(value: 'debug', child: Text('debug')),
                      DropdownMenuItem(value: 'info', child: Text('info')),
                      DropdownMenuItem(value: 'warn', child: Text('warn')),
                      DropdownMenuItem(value: 'error', child: Text('error')),
                    ],
                    onChanged: (value) =>
                        setState(() => _logLevel = value ?? _logLevel),
                  ),
                ),
                const SizedBox(height: 20),
                OverflowBar(
                  alignment: MainAxisAlignment.end,
                  overflowAlignment: OverflowBarAlignment.end,
                  spacing: 12,
                  overflowSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: controller.busy
                          ? null
                          : () => _save(controller),
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('保存并应用'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _preview(controller),
                      icon: const Icon(Icons.code_rounded),
                      label: const Text('查看生成配置'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _save(AppController controller) async {
    final tolerance = int.tryParse(_tolerance.text.trim()) ?? -1;
    if (_url.text.trim().isEmpty ||
        _interval.text.trim().isEmpty ||
        _idle.text.trim().isEmpty) {
      _showError('测速 URL、间隔和空闲超时不能为空');
      return;
    }
    if (tolerance < 0 || tolerance > 65535) {
      _showError('容差必须在 0–65535 毫秒之间');
      return;
    }
    await controller.updateAdvanced(
      (advanced) => advanced
        ..urlTestUrl = _url.text.trim()
        ..urlTestInterval = _interval.text.trim()
        ..urlTestIdleTimeout = _idle.text.trim()
        ..urlTestTolerance = tolerance
        ..logLevel = _logLevel
        ..interruptExistingConnections = _interrupt,
      restart: true,
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('运行参数已应用')));
    }
  }

  Future<void> _preview(AppController controller) async {
    try {
      final compiled = await controller.compileForExport();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('生成的 sing-box 配置'),
          content: SizedBox(
            width: 720,
            height: 520,
            child: SingleChildScrollView(
              child: SelectableText(
                const JsonEncoder.withIndent('  ')
                    .convert(compiled.redactedJson),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await copyText(
                  context,
                  const JsonEncoder.withIndent('  ')
                      .convert(compiled.redactedJson),
                  message: '配置已复制',
                );
              },
              child: const Text('复制'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showError(e.toString());
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
