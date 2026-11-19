import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/header_fade.dart';
import '../../app/widgets.dart';
import '../../state/app_controller.dart';

class RuleSetsPage extends StatelessWidget {
  const RuleSetsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final status = controller.ruleSetStatus;
    return HeaderScaffold(
      title: const Text('规则集'),
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
                  title: '当前规则集',
                  icon: Icons.shield_outlined,
                  child: Column(
                    children: [
                      KeyValueRow(
                        label: '来源',
                        value: status?.sourceLabel ?? '内置规则',
                        expandValue: true,
                      ),
                      KeyValueRow(
                        label: '更新时间',
                        value: _dateText(status?.updatedAt),
                        expandValue: true,
                      ),
                      KeyValueRow(
                        label: '上次检查',
                        value: _dateText(status?.checkedAt),
                        expandValue: true,
                      ),
                      if (status != null)
                        for (final (kind, label) in const [
                          ('geosite', 'GeoSite'),
                          ('geoip', 'GeoIP'),
                        ])
                          KeyValueRow(
                            label: label,
                            value:
                                '${status.count(kind)} 个 · ${_sizeText(status.size(kind))}'
                                ' · ${status.releaseTag(kind) ?? '—'}',
                            expandValue: true,
                          ),
                    ],
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
                      onPressed: controller.updatingRuleSets
                          ? null
                          : controller.updateRuleSets,
                      icon: controller.updatingRuleSets
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync_rounded),
                      label: Text(
                        controller.updatingRuleSets ? '正在检查…' : '检查更新',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: controller.updatingRuleSets
                          ? null
                          : () => _confirmReset(context, controller),
                      icon: const Icon(Icons.restore_rounded),
                      label: const Text('恢复内置'),
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

  Future<void> _confirmReset(
    BuildContext context,
    AppController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复内置规则'),
        content: const Text('将重新启用安装包内置的 GeoSite 和 GeoIP 规则集。确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.resetBuiltInRuleSets();
    }
  }

  static String _dateText(DateTime? value) {
    if (value == null) return '从未';
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  static String _sizeText(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}
