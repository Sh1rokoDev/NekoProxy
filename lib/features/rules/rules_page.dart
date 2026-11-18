import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/widgets.dart';
import '../../domain/config_compiler.dart';
import '../../domain/models.dart';
import '../../state/app_controller.dart';
import 'split_mode_switch.dart';

class RulesPage extends StatefulWidget {
  const RulesPage({super.key});

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  late List<RoutingRule> _rules;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rules = List.of(AppScope.read(context).snapshot.rules);
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    RoutingPreview? preview;
    try {
      preview = controller.previewRouting();
    } on ConfigCompileException {
      preview = null;
    }
    return PageFrame(
      title: '规则',
      actions: SplitModeSwitch(controller: controller),
      wrapHeader: true,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'rules-add',
        tooltip: '添加规则',
        onPressed: () => _showEditor(context, controller),
        icon: const Icon(Icons.add_rounded),
        label: const Text('添加'),
      ),
      child: SectionCard(
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(
            type: MaterialType.transparency,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 520;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (preview == null)
                      const ListTile(title: Text('无法预览生效规则，请检查配置')),
                    if (preview?.overridden == true)
                      const ListTile(
                        title: Text('路由由 JSON 配置接管'),
                        subtitle: Text('下方可编辑规则暂未生效'),
                      ),
                    if (preview != null &&
                        preview.overridden &&
                        preview.coreRules.isNotEmpty)
                      const _JsonRulesHeader(),
                    if (preview != null)
                      for (final (index, rule)
                          in preview.coreRules.indexed) ...[
                        _CompiledRuleTile(
                          key: ValueKey('compiled-rule-$index'),
                          rule: rule,
                          fromJson: preview.overridden,
                          compact: compact,
                        ),
                        _ruleDivider,
                      ],
                    if (_rules.isEmpty)
                      const _EmptyRules()
                    else
                      ReorderableListView.builder(
                        key: const ValueKey('rules-list'),
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        buildDefaultDragHandles: false,
                        proxyDecorator: (child, index, animation) => child,
                        itemCount: _rules.length,
                        onReorderItem: (oldIndex, newIndex) async {
                          setState(() {
                            final item = _rules.removeAt(oldIndex);
                            _rules.insert(newIndex, item);
                          });
                          await controller.saveRules(List.of(_rules));
                        },
                        itemBuilder: (context, index) {
                          final rule = _rules[index];
                          return _EditableRuleRow(
                            key: ValueKey(rule.id),
                            compact: compact,
                            showDivider: index < _rules.length - 1,
                            rule: rule,
                            rulesActive:
                                preview?.activeRuleIds.contains(rule.id) ??
                                false,
                            index: index,
                            onToggle: (value) async {
                              setState(() => rule.enabled = value);
                              await controller.saveRules(List.of(_rules));
                            },
                            onEdit: () =>
                                _showEditor(context, controller, rule: rule),
                          );
                        },
                      ),
                    if (preview != null) ...[
                      _ruleDivider,
                      _DefaultOutbound(
                        compact: compact,
                        label: preview.overridden
                            ? preview.finalOutbound ?? _outboundLabel(null)
                            : _outboundLabel(preview.finalOutbound),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showEditor(
    BuildContext context,
    AppController controller, {
    RoutingRule? rule,
  }) async {
    final editing = rule != null;
    final name = TextEditingController(text: rule?.name ?? '');
    final singleValue = TextEditingController(text: rule?.value ?? '');
    var logic = rule?.logic ?? RuleLogic.single;
    var kind = rule?.kind ?? RuleKind.domainSuffix;
    var target = rule?.target ?? RuleTarget.proxy;
    final drafts = <_ConditionDraft>[
      if (rule != null && rule.conditions.isNotEmpty)
        for (final condition in rule.conditions)
          _ConditionDraft(condition.kind, condition.value)
      else
        _ConditionDraft(kind, rule?.value ?? ''),
    ];
    final retired = <TextEditingController>[];
    String? errorText;

    String? validateCondition(
      RuleKind conditionKind,
      String raw,
      String label,
    ) {
      if (!conditionKind.takesValue) return null;
      final text = raw.trim();
      if (text.isEmpty) return '请填写$label';
      if (conditionKind == RuleKind.ruleSet) {
        final unknown = splitRuleSetTags(text)
            .where((item) => !controller.ruleSets.tags.contains(item))
            .toList();
        if (unknown.isNotEmpty) return '未知规则集：${unknown.join('、')}';
      }
      return null;
    }

    Future<void> pickRuleSet(
      BuildContext context,
      TextEditingController field,
    ) async {
      final tags = controller.ruleSets.tags.toList()..sort();
      final selected = await _pickRuleSet(context, tags);
      if (!context.mounted || selected == null) return;
      if (splitRuleSetTags(field.text).contains(selected)) return;
      final previous = field.text.trim();
      field.text = previous.isEmpty ? selected : '$previous\n$selected';
    }

    String? validate() {
      if (name.text.trim().isEmpty) return '请输入规则名称';
      if (logic == RuleLogic.single) {
        return validateCondition(kind, singleValue.text, '匹配内容');
      }
      if (drafts.length < 2) return 'AND/OR 规则至少需要两个条件';
      for (var index = 0; index < drafts.length; index++) {
        final problem = validateCondition(
          drafts[index].kind,
          drafts[index].value.text,
          '第 ${index + 1} 个条件',
        );
        if (problem != null) return problem;
      }
      return null;
    }

    void disposeAll() {
      name.dispose();
      singleValue.dispose();
      for (final draft in drafts) {
        draft.value.dispose();
      }
      for (final controller in retired) {
        controller.dispose();
      }
    }

    try {
      final result = await showDialog<_EditorResult>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) {
            final scheme = Theme.of(context).colorScheme;
            final availableKinds = _availableRuleKinds();
            return AlertDialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 24,
              ),
              title: Text(editing ? '编辑规则' : '添加规则'),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: name,
                        decoration: const InputDecoration(labelText: '规则名称'),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<RuleLogic>(
                              initialValue: logic,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '匹配方式',
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: RuleLogic.single,
                                  child: Text('单一条件'),
                                ),
                                DropdownMenuItem(
                                  value: RuleLogic.and,
                                  child: Text('全部 AND'),
                                ),
                                DropdownMenuItem(
                                  value: RuleLogic.or,
                                  child: Text('任一 OR'),
                                ),
                              ],
                              onChanged: (value) {
                                if (value == null) return;
                                setDialogState(() {
                                  if (value == RuleLogic.single) {
                                    if (drafts.isNotEmpty) {
                                      kind = drafts.first.kind;
                                      singleValue.text =
                                          drafts.first.value.text;
                                    }
                                  } else if (logic == RuleLogic.single) {
                                    drafts.first.kind = kind;
                                    drafts.first.value.text = singleValue.text;
                                    while (drafts.length < 2) {
                                      drafts.add(_ConditionDraft(kind, ''));
                                    }
                                  }
                                  logic = value;
                                  errorText = null;
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<RuleTarget>(
                              initialValue: target,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '动作',
                              ),
                              items: RuleTarget.values
                                  .map(
                                    (value) => DropdownMenuItem(
                                      value: value,
                                      child: Text(
                                        _ruleTargetLongLabel(value),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (value) => setDialogState(
                                () => target = value ?? target,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (logic == RuleLogic.single) ...[
                        DropdownButtonFormField<RuleKind>(
                          initialValue: kind,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '匹配类型'),
                          items: availableKinds
                              .map(
                                (value) => DropdownMenuItem(
                                  value: value,
                                  child: Text(_ruleKindLabel(value)),
                                ),
                              )
                              .toList(),
                          onChanged: (value) =>
                              setDialogState(() => kind = value ?? kind),
                        ),
                        if (kind.takesValue) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: singleValue,
                            minLines: 2,
                            maxLines: 5,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                            decoration: InputDecoration(
                              labelText: '匹配内容',
                              hintText: _ruleKindHint(kind),
                              suffixIcon: kind == RuleKind.ruleSet
                                  ? IconButton(
                                      tooltip: '选择规则集',
                                      icon: const Icon(Icons.search_rounded),
                                      onPressed: () =>
                                          pickRuleSet(context, singleValue),
                                    )
                                  : null,
                            ),
                          ),
                        ],
                      ] else ...[
                        for (var index = 0; index < drafts.length; index++)
                          Padding(
                            key: ObjectKey(drafts[index]),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest
                                    .withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    flex: 4,
                                    child: DropdownButtonFormField<RuleKind>(
                                      initialValue: drafts[index].kind,
                                      isExpanded: true,
                                      decoration: InputDecoration(
                                        labelText: '条件 ${index + 1}',
                                        border: InputBorder.none,
                                        isDense: true,
                                      ),
                                      items: availableKinds
                                          .map(
                                            (value) => DropdownMenuItem(
                                              value: value,
                                              child: Text(
                                                _ruleKindLabel(value),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: (value) => setDialogState(
                                        () => drafts[index].kind =
                                            value ?? drafts[index].kind,
                                      ),
                                    ),
                                  ),
                                  if (drafts[index].kind.takesValue) ...[
                                    const SizedBox(width: 8),
                                    Expanded(
                                      flex: 5,
                                      child: TextField(
                                        controller: drafts[index].value,
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 12,
                                        ),
                                        decoration: InputDecoration(
                                          labelText: '内容',
                                          hintText: _ruleKindHint(
                                            drafts[index].kind,
                                          ),
                                          suffixIcon:
                                              drafts[index].kind ==
                                                  RuleKind.ruleSet
                                              ? IconButton(
                                                  tooltip: '选择规则集',
                                                  icon: const Icon(
                                                    Icons.search_rounded,
                                                  ),
                                                  onPressed: () => pickRuleSet(
                                                    context,
                                                    drafts[index].value,
                                                  ),
                                                )
                                              : null,
                                          border: InputBorder.none,
                                          isDense: true,
                                        ),
                                      ),
                                    ),
                                  ],
                                  IconButton(
                                    onPressed: drafts.length <= 2
                                        ? null
                                        : () => setDialogState(() {
                                            final removed = drafts.removeAt(
                                              index,
                                            );
                                            retired.add(removed.value);
                                          }),
                                    tooltip: '移除条件',
                                    visualDensity: VisualDensity.compact,
                                    iconSize: 19,
                                    icon: const Icon(
                                      Icons.remove_circle_outline_rounded,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => setDialogState(() {
                              drafts.add(_ConditionDraft(drafts.last.kind, ''));
                            }),
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('添加条件'),
                          ),
                        ),
                        Text(
                          'AND 需要全部条件同时成立，OR 任一条件成立即可。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                      if (errorText != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          errorText!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                if (editing)
                  TextButton(
                    onPressed: () =>
                        Navigator.pop(context, _EditorResult.delete),
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                    child: const Text('删除'),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final problem = validate();
                    if (problem != null) {
                      setDialogState(() => errorText = problem);
                      return;
                    }
                    Navigator.pop(context, _EditorResult.save);
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        ),
      );
      if (result == null) return;
      if (result == _EditorResult.delete && editing) {
        if (!context.mounted) return;
        final confirmed = await confirmDialog(
          context,
          title: '删除规则',
          message: '删除「${rule.name}」？',
          confirmLabel: '删除',
          destructive: true,
        );
        if (confirmed && mounted) {
          setState(() => _rules.removeWhere((item) => item.id == rule.id));
          await controller.saveRules(List.of(_rules));
        }
        return;
      }
      final conditions = logic == RuleLogic.single
          ? <RuleCondition>[]
          : [
              for (final draft in drafts)
                RuleCondition(
                  kind: draft.kind,
                  value: draft.kind.takesValue ? draft.value.text.trim() : '',
                ),
            ];
      final updated = RoutingRule(
        id: editing
            ? rule.id
            : DateTime.now().microsecondsSinceEpoch.toString(),
        name: name.text.trim(),
        kind: logic == RuleLogic.single ? kind : conditions.first.kind,
        value: logic == RuleLogic.single
            ? (kind.takesValue ? singleValue.text.trim() : '')
            : conditions.first.value,
        target: target,
        enabled: editing ? rule.enabled : true,
        logic: logic,
        conditions: conditions,
        builtInId: editing ? rule.builtInId : null,
      );
      if (editing) {
        final index = _rules.indexWhere((item) => item.id == rule.id);
        if (index >= 0) {
          setState(() => _rules[index] = updated);
        }
      } else {
        // Custom rules must stay ahead of the built-in bypass rules.
        var index = _rules.indexWhere((item) {
          final id = item.builtInId;
          return id != null &&
              builtInRules.any(
                (other) => other.id == id && other.target != RuleTarget.block,
              );
        });
        if (index < 0) {
          index = _rules.indexWhere(
            (item) =>
                item.kind == RuleKind.ruleSet &&
                item.target != RuleTarget.block &&
                splitRuleValues(item.value).any(builtInRuleSetTags.contains),
          );
        }
        setState(
          () => _rules.insert(index < 0 ? _rules.length : index, updated),
        );
      }
      await controller.saveRules(List.of(_rules));
    } finally {
      disposeAll();
    }
  }
}

Future<String?> _pickRuleSet(BuildContext context, List<String> tags) {
  var matches = tags;
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('选择规则集'),
        content: SizedBox(
          width: 400,
          height: 360,
          child: Column(
            children: [
              TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '搜索 GeoSite / GeoIP',
                ),
                onChanged: (value) {
                  final query = value.trim().toLowerCase().replaceFirst(
                    ':',
                    '-',
                  );
                  setState(() {
                    matches = tags.where((tag) => tag.contains(query)).toList();
                  });
                },
              ),
              Expanded(
                child: matches.isEmpty
                    ? const Center(child: Text('没有匹配的规则集'))
                    : ListView.builder(
                        itemCount: matches.length,
                        itemBuilder: (context, index) {
                          final tag = matches[index];
                          return ListTile(
                            title: Text(_ruleSetLabel(tag)),
                            onTap: () => Navigator.pop(context, tag),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    ),
  );
}

class _ConditionDraft {
  _ConditionDraft(this.kind, String value)
    : value = TextEditingController(text: value);

  RuleKind kind;
  final TextEditingController value;
}

enum _EditorResult { save, delete }

List<RuleKind> _availableRuleKinds() {
  return RuleKind.values
      .where(
        (value) =>
            (value != RuleKind.processName && value != RuleKind.processPath) ||
            Platform.isWindows,
      )
      .where((value) => value != RuleKind.packageName || Platform.isAndroid)
      .toList();
}

class _CompiledRuleTile extends StatelessWidget {
  const _CompiledRuleTile({
    super.key,
    required this.rule,
    required this.fromJson,
    required this.compact,
  });

  final Map<String, dynamic> rule;
  final bool fromJson;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final action = rule['action'];
    final (title, description) = switch (action) {
      'sniff' => ('识别流量协议', '按 DNS 设置执行流量嗅探，继续匹配后续规则'),
      'hijack-dns' => ('DNS 接管', '将命中的 DNS 查询交给 sing-box 的解析器'),
      'reject' when !fromJson && rule['inbound'] != null => (
        '拒绝 WireGuard 入站',
        '拒绝对端主动发起的连接',
      ),
      'reject' => ('阻断', '拒绝匹配此规则的连接'),
      'route' || null when rule['outbound'] is String => (
        '路由到 ${_outboundLabel(rule['outbound'] as String)}',
        '匹配后选择指定出站',
      ),
      _ => ('${action ?? '路由'}', '点击查看匹配条件和动作'),
    };
    return _RuleRow(
      compact: compact,
      leading: const Icon(Icons.lock_outline_rounded),
      title: title,
      description: description,
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          title: Text(title),
          scrollable: true,
          content: SizedBox(
            width: 560,
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(rule),
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }
}

String _outboundLabel(String? tag) => switch (tag) {
  ConfigCompiler.directTag => '直连',
  ConfigCompiler.proxyTag => '手动选择',
  ConfigCompiler.autoTag => '自动选择',
  ConfigCompiler.wireGuardTag => 'WireGuard',
  null => '核心默认出站',
  _ => tag,
};

TextStyle? _ruleDetailStyle(ThemeData theme) => theme.textTheme.bodySmall
    ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

class _JsonRulesHeader extends StatelessWidget {
  const _JsonRulesHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = _ruleDetailStyle(theme)
        ?.copyWith(fontWeight: FontWeight.w600);
    return ColoredBox(
      color: Color.alphaBlend(
        theme.colorScheme.onSurface.withValues(alpha: 0.04),
        theme.colorScheme.surfaceContainerLow,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Semantics(header: true, child: Text('JSON 规则', style: style)),
      ),
    );
  }
}

class _DefaultOutbound extends StatelessWidget {
  const _DefaultOutbound({required this.label, required this.compact});

  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return _RuleRow(
      compact: compact,
      leading: const Icon(Icons.alt_route_rounded),
      title: '默认出站',
      description: '未命中规则时：$label',
    );
  }
}

class _EmptyRules extends StatelessWidget {
  const _EmptyRules();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        '暂无可编辑规则',
        textAlign: TextAlign.center,
        style: _ruleDetailStyle(Theme.of(context)),
      ),
    );
  }
}

const _ruleDivider = Divider(height: 1, indent: 56, endIndent: 16);

class _RuleRow extends StatelessWidget {
  const _RuleRow({
    required this.compact,
    required this.leading,
    required this.title,
    required this.description,
    this.titleColor,
    this.controls = const [],
    this.onTap,
  });

  final bool compact;
  final Widget leading;
  final String title;
  final String description;
  final Color? titleColor;
  final List<Widget> controls;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final interactive = onTap != null;
    return InkWell(
      onTap: onTap,
      // Rows without an action still show ink feedback for pointer presses.
      onTapDown: interactive ? null : (_) {},
      canRequestFocus: interactive,
      mouseCursor: interactive ? null : SystemMouseCursors.basic,
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, 4, compact ? 8 : 16, 4),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              height: 48,
              child: IconTheme.merge(
                data: IconThemeData(size: 18, color: scheme.onSurfaceVariant),
                child: leading,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: compact ? 56 : 0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: titleColor ?? scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      maxLines: compact ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: _ruleDetailStyle(theme),
                    ),
                  ],
                ),
              ),
            ),
            if (controls.isNotEmpty) const SizedBox(width: 8),
            ...controls,
          ],
        ),
      ),
    );
  }
}

class _EditableRuleRow extends StatelessWidget {
  const _EditableRuleRow({
    super.key,
    required this.rule,
    required this.rulesActive,
    required this.compact,
    required this.showDivider,
    required this.index,
    required this.onToggle,
    required this.onEdit,
  });

  final RoutingRule rule;
  final bool rulesActive;
  final bool compact;
  final bool showDivider;
  final int index;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = rulesActive && rule.enabled;
    final (actionBackground, actionForeground) = switch (rule.target) {
      RuleTarget.direct => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      RuleTarget.proxy => (scheme.primaryContainer, scheme.onPrimaryContainer),
      RuleTarget.block when active => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    final actionStyle = _ruleDetailStyle(theme)
        ?.copyWith(fontWeight: FontWeight.w500, color: actionForeground);
    final preview = _rulePreview(rule);
    return Material(
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          _RuleRow(
            compact: compact,
            leading: ReorderableDragStartListener(
              index: index,
              child: const MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Tooltip(
                  message: '拖动调整顺序',
                  child: Icon(Icons.drag_indicator_rounded),
                ),
              ),
            ),
            title: rule.name,
            titleColor: active ? null : scheme.onSurfaceVariant,
            description: rule.enabled && !rulesActive
                ? '未生效 · $preview'
                : preview,
            controls: [
              DecoratedBox(
                decoration: ShapeDecoration(
                  color: actionBackground,
                  shape: const StadiumBorder(),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    _ruleTargetShortLabel(rule.target),
                    style: actionStyle,
                  ),
                ),
              ),
              IconButton(
                tooltip: '编辑规则',
                onPressed: onEdit,
                color: scheme.onSurfaceVariant,
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
              SizedBox(
                width: 64,
                child: Center(
                  child: Semantics(
                    label: '启用 ${rule.name}',
                    child: Switch(
                      value: rule.enabled,
                      onChanged: onToggle,
                      activeTrackColor: rulesActive
                          ? null
                          : scheme.surfaceContainerHighest,
                      activeThumbColor: rulesActive
                          ? null
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (showDivider) _ruleDivider,
        ],
      ),
    );
  }
}

String _rulePreview(RoutingRule rule) {
  if (rule.isLogical) {
    final separator = rule.logic == RuleLogic.or ? ' | ' : ' · ';
    return rule.conditions.map(_conditionPreview).join(separator);
  }
  return _conditionPreview(RuleCondition(kind: rule.kind, value: rule.value));
}

String _conditionPreview(RuleCondition condition) {
  final values = splitRuleValues(condition.value)
      .map(
        (item) =>
            condition.kind == RuleKind.ruleSet ? _ruleSetLabel(item) : item,
      )
      .toList();
  if (values.isEmpty) return _ruleKindLabel(condition.kind);
  final shown = values.take(2).join(', ');
  final extra = values.length - 2;
  final text = extra > 0 ? '$shown, +$extra' : shown;
  return '${_ruleKindLabel(condition.kind)} $text';
}

String _ruleSetLabel(String tag) {
  if (tag.startsWith('geosite-')) {
    return 'geosite:${tag.substring('geosite-'.length)}';
  }
  if (tag.startsWith('geoip-')) {
    return 'geoip:${tag.substring('geoip-'.length)}';
  }
  return tag;
}

String _ruleKindLabel(RuleKind kind) => switch (kind) {
  RuleKind.domain => '域名',
  RuleKind.domainSuffix => '域名后缀',
  RuleKind.domainKeyword => '域名关键词',
  RuleKind.domainRegex => '域名正则',
  RuleKind.privateIp => '私网地址',
  RuleKind.ipCidr => 'IP 网段',
  RuleKind.sourceIpCidr => '来源 IP',
  RuleKind.port => '端口',
  RuleKind.sourcePort => '来源端口',
  RuleKind.network => '网络',
  RuleKind.protocol => '协议',
  RuleKind.processName => '进程名',
  RuleKind.processPath => '进程路径',
  RuleKind.packageName => '包名',
  RuleKind.ruleSet => '规则集',
};

String _ruleTargetLongLabel(RuleTarget target) => switch (target) {
  RuleTarget.proxy => '按当前选择',
  RuleTarget.direct => '直连',
  RuleTarget.block => '阻断',
  RuleTarget.manualGroup => '手动组',
  RuleTarget.autoGroup => '自动组',
};

String _ruleTargetShortLabel(RuleTarget target) => switch (target) {
  RuleTarget.proxy => '代理',
  RuleTarget.direct => '直连',
  RuleTarget.block => '阻断',
  RuleTarget.manualGroup => '手动组',
  RuleTarget.autoGroup => '自动组',
};

String _ruleKindHint(RuleKind kind) => switch (kind) {
  RuleKind.ipCidr || RuleKind.sourceIpCidr => '10.0.0.0/8, 192.168.0.0/16',
  RuleKind.port || RuleKind.sourcePort => '443, 8443',
  RuleKind.network => 'tcp 或 udp',
  RuleKind.protocol => 'http、tls、quic…',
  RuleKind.ruleSet => 'geosite-cn、geoip-cn、geosite-category-ads-all',
  RuleKind.domainRegex => r'^ads\.example\.com$',
  RuleKind.processName => 'chrome.exe, Telegram.exe',
  RuleKind.processPath => r'C:\Program Files\App\app.exe',
  RuleKind.packageName => 'com.example.app, org.telegram.messenger',
  _ => 'example.com',
};
