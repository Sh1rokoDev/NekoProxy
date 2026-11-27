import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../app/header_fade.dart';
import '../../app/widgets.dart';
import '../../domain/config_compiler.dart';
import '../../domain/config_policy.dart';
import '../../domain/models.dart';
import '../../state/app_controller.dart';

class ConfigPage extends StatefulWidget {
  const ConfigPage({super.key});

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  late final TextEditingController _advanced;
  late final TextEditingController _custom;
  late AdvancedConfigMode _mode;
  bool _saving = false;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final snapshot = AppScope.read(context).snapshot;
    final advancedJson = snapshot.advancedJsonDraft;
    _advanced = TextEditingController(
      text: advancedJson.isEmpty
          ? '{\n  \n}'
          : const JsonEncoder.withIndent('  ').convert(advancedJson),
    );
    _custom = TextEditingController(text: snapshot.customConfig);
    _mode = snapshot.advancedConfigMode;
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
    final isCustom = _mode == AdvancedConfigMode.override;
    final editor = isCustom ? _custom : _advanced;
    final page = HeaderScaffold(
      title: const FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: Text('高级配置', maxLines: 1),
      ),
      actions: [
        SlidingSegmentedControl<AdvancedConfigMode>(
          width: 144,
          segments: const [
            SlidingSegmentOption(value: AdvancedConfigMode.off, label: '关闭'),
            SlidingSegmentOption(
              value: AdvancedConfigMode.extension,
              label: '扩展',
            ),
            SlidingSegmentOption(
              value: AdvancedConfigMode.override,
              label: '覆盖',
            ),
          ],
          selected: _mode,
          onChanged: _saving ? null : (value) => setState(() => _mode = value),
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'save-advanced-config',
        onPressed: controller.busy || _saving ? null : () => _save(controller),
        icon: const Icon(Icons.save_outlined),
        label: const Text('保存并应用'),
      ),
      maxContentWidth: 980,
      scrollsBehindHeader: false,
      body: (_) => Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          16,
          24,
          88 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: _mode == AdvancedConfigMode.off
                ? const Text('使用应用生成的配置')
                : _buildEditor(controller, editor, isCustom: isCustom),
          ),
        ),
      ),
    );
    return PopScope(canPop: !_saving, child: page);
  }

  Widget _buildEditor(
    AppController controller,
    TextEditingController editor, {
    required bool isCustom,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildEditorActions(controller, editor, isCustom: isCustom),
        const SizedBox(height: 12),
        Expanded(
          child: TextField(
            key: ValueKey(isCustom),
            controller: editor,
            readOnly: _saving,
            expands: true,
            maxLines: null,
            textAlignVertical: TextAlignVertical.top,
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
        ),
      ],
    );
  }

  Widget _buildEditorActions(
    AppController controller,
    TextEditingController editor, {
    required bool isCustom,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showIcons =
            constraints.maxWidth >= MediaQuery.textScalerOf(context).scale(300);
        final style = OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          iconSize: 16,
        );
        Widget button(String label, IconData icon, VoidCallback onPressed) {
          return OutlinedButton.icon(
            style: style,
            onPressed: _saving ? null : onPressed,
            icon: showIcons ? Icon(icon) : null,
            label: Text(label),
          );
        }

        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            button(
              '格式化',
              Icons.format_align_left_rounded,
              () => _prettyPrint(editor),
            ),
            button('校验', Icons.rule_rounded, () => _validateJson(editor)),
            if (isCustom)
              button(
                '载入完整配置',
                Icons.auto_fix_high_rounded,
                () => _loadGenerated(controller),
              ),
          ],
        );
      },
    );
  }

  Future<void> _save(AppController controller) async {
    final mode = _mode;
    final text = switch (mode) {
      AdvancedConfigMode.extension => _advanced.text,
      AdvancedConfigMode.override => _custom.text,
      AdvancedConfigMode.off => '',
    };
    setState(() => _saving = true);
    try {
      await controller.saveAdvancedConfig(mode, text);
      if (mounted) {
        _showInfo(switch (mode) {
          AdvancedConfigMode.extension => '已应用高级 JSON 扩展',
          AdvancedConfigMode.override => '已应用完整配置',
          AdvancedConfigMode.off => '已关闭高级配置',
        });
      }
    } on FormatException catch (error) {
      if (mounted) _showError(error.message);
    } catch (error) {
      if (mounted) _showError('保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _validateJson(TextEditingController editor) {
    try {
      final decoded = jsonDecode(editor.text);
      if (decoded is! Map) throw const FormatException('根节点必须是 JSON 对象');
      if (CompiledConfig.containsRedactedValue(decoded)) {
        throw const FormatException('请替换预览中的脱敏占位符后再使用此配置');
      }
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
    final confirmed = await confirmDialog(
      context,
      title: '载入完整配置',
      message: '编辑器将显示节点密码和私钥等凭据，并替换当前草稿。',
      confirmLabel: '载入',
    );
    if (!confirmed ||
        !mounted ||
        _saving ||
        _mode != AdvancedConfigMode.override ||
        _custom.text != previousText) {
      return;
    }
    try {
      final compiled = await controller.compileForExport();
      if (!mounted ||
          _saving ||
          _mode != AdvancedConfigMode.override ||
          _custom.text != previousText) {
        return;
      }
      _custom.text = compiled.encoded;
      _showInfo('已载入当前配置。请检查后保存并应用。');
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
