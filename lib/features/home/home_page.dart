import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/widgets.dart';
import '../../domain/models.dart';
import '../../state/app_controller.dart';
import '../status/service_status.dart';
import 'connection_card.dart';
import 'home_cards.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  HomeLayout? _draft;
  bool _editingDesktop = false;
  bool _saving = false;

  String _label(HomeCard card) => switch (card) {
    HomeCard.connection => '连接与出口信息',
    HomeCard.splitMode => '规则模式',
    HomeCard.traffic => '实时流量',
    HomeCard.subscription => '订阅用量',
    HomeCard.services => '服务状态',
    HomeCard.activity => '最近活动',
  };

  Future<void> _edit(AppController controller, bool desktop) async {
    final draft = _draft;
    if (draft == null) {
      final saved = desktop
          ? controller.settings.homeDesktop
          : controller.settings.homeMobile;
      setState(() {
        _editingDesktop = desktop;
        _draft = HomeLayout(order: saved.order, hidden: saved.hidden);
      });
      return;
    }
    setState(() => _saving = true);
    try {
      await controller.saveHomeLayout(draft, desktop: _editingDesktop);
      if (mounted) setState(() => _draft = null);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('首页布局保存失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _editor(HomeLayout draft) => SectionCard(
    title: '编辑${_editingDesktop ? '桌面' : '手机'}首页',
    icon: Icons.dashboard_customize_outlined,
    trailing: TextButton(
      onPressed: _saving ? null : () => setState(() => _draft = null),
      child: const Text('取消'),
    ),
    child: Column(
      children: [
        for (var index = 0; index < draft.order.length; index++)
          Row(
            children: [
              Checkbox(
                value: !draft.hidden.contains(draft.order[index]),
                onChanged: _saving || draft.order[index] == HomeCard.connection
                    ? null
                    : (value) => setState(() {
                        if (value == true) {
                          draft.hidden.remove(draft.order[index]);
                        } else {
                          draft.hidden.add(draft.order[index]);
                        }
                      }),
              ),
              Expanded(child: Text(_label(draft.order[index]))),
              IconButton(
                tooltip: '上移${_label(draft.order[index])}',
                onPressed: _saving || index == 0
                    ? null
                    : () => setState(() {
                        final card = draft.order.removeAt(index);
                        draft.order.insert(index - 1, card);
                      }),
                icon: const Icon(Icons.arrow_upward_rounded, size: 18),
              ),
              IconButton(
                tooltip: '下移${_label(draft.order[index])}',
                onPressed: _saving || index == draft.order.length - 1
                    ? null
                    : () => setState(() {
                        final card = draft.order.removeAt(index);
                        draft.order.insert(index + 1, card);
                      }),
                icon: const Icon(Icons.arrow_downward_rounded, size: 18),
              ),
            ],
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    return LayoutBuilder(
      builder: (context, pageConstraints) {
        final desktop = pageConstraints.maxWidth >= 760;
        final layout = _draft != null && _editingDesktop == desktop
            ? _draft!
            : desktop
            ? controller.settings.homeDesktop
            : controller.settings.homeMobile;
        Widget card(HomeCard kind) => KeyedSubtree(
          key: ValueKey(kind),
          child: switch (kind) {
            HomeCard.connection => ConnectionCard(
              controller: controller,
              hasNodes: controller.hasNodes,
            ),
            HomeCard.splitMode => HomeSplitModeCard(controller: controller),
            HomeCard.traffic => HomeTrafficCard(controller: controller),
            HomeCard.subscription => HomeSubscriptionCard(
              controller: controller,
            ),
            HomeCard.services => ServiceStatusCard(controller: controller),
            HomeCard.activity => HomeActivityCard(controller: controller),
          },
        );
        Widget column(List<HomeCard> cards) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final kind in cards)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: card(kind),
              ),
          ],
        );
        final visible = layout.order
            .where((kind) => !layout.hidden.contains(kind))
            .toList();
        final sections = <Widget>[];
        if (_draft case final draft?) {
          sections.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _editor(draft),
            ),
          );
        }
        // The connection card spans both columns.
        final pending = <HomeCard>[];
        void flush() {
          if (pending.isEmpty) return;
          if (desktop) {
            final left = <HomeCard>[];
            final right = <HomeCard>[];
            var placeLeft = true;
            for (final kind in pending) {
              if (kind == HomeCard.splitMode) {
                // Keep the shortcut in the narrow column without shifting
                // the alternating placement of the other cards.
                right.add(kind);
              } else {
                (placeLeft ? left : right).add(kind);
                placeLeft = !placeLeft;
              }
            }
            sections.add(
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 7, child: column(left)),
                  const SizedBox(width: 16),
                  Expanded(flex: 5, child: column(right)),
                ],
              ),
            );
          } else {
            sections.add(column(pending));
          }
          pending.clear();
        }

        for (final kind in visible) {
          if (kind == HomeCard.connection) {
            flush();
            sections.add(
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: card(kind),
              ),
            );
          } else {
            pending.add(kind);
          }
        }
        flush();
        return PageFrame(
          title: '首页',
          scrollable: false,
          wrapHeader: true,
          actions: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _NetworkTakeoverActions(controller: controller),
              const SizedBox(width: 8),
              HeaderIconButton(
                icon: _draft == null
                    ? Icons.edit_outlined
                    : Icons.check_rounded,
                tooltip: _draft == null ? '编辑首页' : '完成编辑',
                active: _draft != null,
                onPressed: _saving ? null : () => _edit(controller, desktop),
              ),
            ],
          ),
          child: Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: sections,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NetworkTakeoverActions extends StatelessWidget {
  const _NetworkTakeoverActions({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = !controller.busy;
    final items = <Widget>[
      if (controller.isAndroid)
        _CompactSwitch(
          icon: Icons.vpn_key_rounded,
          label: 'VPN',
          value: controller.running,
          enabled: enabled,
          onChanged: (value) =>
              value ? controller.connect() : controller.disconnect(),
        )
      else ...[
        _CompactSwitch(
          icon: Icons.lan_outlined,
          label: 'TUN',
          value: controller.settings.tunEnabled,
          enabled: enabled,
          onChanged: (value) => controller.setTun(value),
        ),
        if (controller.supportsSystemProxy)
          _CompactSwitch(
            icon: Icons.language_rounded,
            label: '系统代理',
            value: controller.settings.systemProxyEnabled,
            enabled: enabled,
            onChanged: (value) => controller.setSystemProxy(value),
          ),
      ],
    ];
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < items.length; index++) ...[
            if (index > 0)
              Container(
                width: 1,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            items[index],
          ],
        ],
      ),
    );
  }
}

class _CompactSwitch extends StatelessWidget {
  const _CompactSwitch({
    required this.icon,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    void toggle() {
      if (enabled) onChanged(!value);
    }

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: toggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(7, 2, 3, 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: enabled
                  ? (value ? scheme.primary : scheme.onSurfaceVariant)
                  : scheme.outline,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: enabled ? scheme.onSurfaceVariant : scheme.outline,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 1),
            SizedBox(
              width: 42,
              height: 30,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Switch(
                  value: value,
                  onChanged: enabled ? onChanged : null,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
