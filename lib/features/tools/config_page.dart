import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/header_fade.dart';
import '../../app/widgets.dart';
import '../../domain/config_policy.dart';
import '../../state/app_controller.dart';

class ConfigPage extends StatefulWidget {
  const ConfigPage({super.key});

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  late final TextEditingController _advanced;
  late final TextEditingController _custom;
  bool _customEnabled = false;
  int _tab = 0;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final controller = AppScope.read(context);
    _advanced = TextEditingController(
      text: controller.snapshot.advancedJson.isEmpty
          ? '{\n  \n}'
          : const JsonEncoder.withIndent('  ')
                .convert(controller.snapshot.advancedJson),
    );
    _custom = TextEditingController(text: controller.snapshot.customConfig);
    _customEnabled = controller.snapshot.useCustomConfig;
  }

  @override
  void dispose() {
    _advanced.dispose();
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final theme = Theme.of(context);
    final isCustom = _tab == 1;
    final editor = isCustom ? _custom : _advanced;
    return HeaderScaffold(
      title: const Text('高级配置'),
      scrollsBehindHeader: false,
      fadeTail: 8,
      body: (_) => Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 14),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: SlidingSegmentedControl<int>(
                  width: double.infinity,
                  height: 48,
                  segments: const [
                    SlidingSegmentOption(
                      value: 0,
                      label: 'JSON 扩展',
                      icon: Icons.merge_type_rounded,
                    ),
                    SlidingSegmentOption(
                      value: 1,
                      label: '自定义配置',
                      icon: Icons.data_object_rounded,
                    ),
                  ],
                  selected: _tab,
                  onChanged: (value) => setState(() => _tab = value),
                ),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 980),
                  child: _buildEditor(controller, editor, isCustom: isCustom),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
            color: theme.colorScheme.surfaceContainer,
            child: SafeArea(
              top: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 980),
                  child: Row(
                    children: [
                      if (isCustom) ...[
                        Expanded(
                          child: Text(
                            '启用完整配置',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        Switch(
                          value: _customEnabled,
                          onChanged: controller.busy
                              ? null
                              : (value) => _saveCustom(controller, value),
                        ),
                        const SizedBox(width: 12),
                      ] else
                        const Spacer(),
                      FilledButton.icon(
                        onPressed: controller.busy
                            ? null
                            : isCustom
                            ? () => _saveCustom(controller, _customEnabled)
                            : () => _saveAdvanced(controller),
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('保存并应用'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditor(
    AppController controller,
    TextEditingController editor, {
    required bool isCustom,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => _prettyPrint(editor),
              icon: const Icon(Icons.format_align_left_rounded),
              label: const Text('格式化'),
            ),
            OutlinedButton.icon(
              onPressed: () => _validateJson(editor),
              icon: const Icon(Icons.rule_rounded),
              label: const Text('校验'),
            ),
            if (isCustom)
              OutlinedButton.icon(
                onPressed: () => _loadGenerated(controller),
                icon: const Icon(Icons.auto_fix_high_rounded),
                label: const Text('载入当前生成配置'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          key: ValueKey(isCustom),
          controller: editor,
          minLines: 22,
          maxLines: 34,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.45,
          ),
          decoration: InputDecoration(
            labelText: isCustom ? '完整 sing-box 配置（JSON）' : '高级 JSON 扩展',
            alignLabelWithHint: true,
            hintText: '{\n  "inbounds": [],\n  "outbounds": []\n}',
          ),
        ),
      ],
    );
  }

  Future<void> _saveAdvanced(AppController controller) async {
    try {
      final decoded = jsonDecode(_advanced.text);
      if (decoded is! Map) throw const FormatException('根节点必须是 JSON 对象');
      final map = Map<String, dynamic>.from(decoded);
      final violations = ConfigPolicy.validate(map);
      if (violations.isNotEmpty) {
        _showError('包含被禁止的设置：${violations.map((e) => e.message).join('；')}');
        return;
      }
      await controller.saveAdvancedJson(map);
      if (mounted) _showInfo('高级配置已保存并应用');
    } catch (e) {
      _showError('JSON 无效：$e');
    }
  }

  Future<void> _saveCustom(AppController controller, bool enabled) async {
    try {
      final violations = ConfigPolicy.validateText(_custom.text.trim());
      if (violations.isNotEmpty) {
        _showError('配置被拒绝：${violations.map((e) => e.message).join('；')}');
        return;
      }
      if (enabled && _custom.text.trim().isEmpty) {
        _showError('请先填写完整配置');
        return;
      }
      setState(() => _customEnabled = enabled);
      await controller.setCustomConfig(_custom.text, enabled);
      if (mounted) _showInfo(enabled ? '已启用完整自定义配置' : '已恢复由 NekoProxy 管理的配置');
    } catch (e) {
      _showError('$e');
    }
  }

  void _validateJson(TextEditingController editor) {
    try {
      final decoded = jsonDecode(editor.text);
      if (decoded is! Map) throw const FormatException('根节点必须是 JSON 对象');
      final violations = ConfigPolicy.validate(
        Map<String, dynamic>.from(decoded),
      );
      if (violations.isEmpty) {
        _showInfo('JSON 结构有效，且不包含被禁止的设置');
      } else {
        _showError(violations.map((e) => e.toString()).join('\n'));
      }
    } catch (e) {
      _showError('JSON 无效：$e');
    }
  }

  void _prettyPrint(TextEditingController controller) {
    try {
      final decoded = jsonDecode(controller.text);
      controller.text = const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (e) {
      _showError('JSON 无效：$e');
    }
  }

  Future<void> _loadGenerated(AppController controller) async {
    final previousText = _custom.text;
    try {
      final compiled = await controller.compileForExport();
      if (!mounted || _custom.text != previousText) return;
      setState(() {
        _custom.text = const JsonEncoder.withIndent('  ')
            .convert(compiled.redactedJson);
      });
      _showInfo('已载入当前生成配置。请检查后再启用完整配置。');
    } catch (e) {
      if (!mounted) return;
      _showError('$e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
    );
  }

  void _showInfo(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
