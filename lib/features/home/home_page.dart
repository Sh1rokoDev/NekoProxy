import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../app/dialogs.dart';
import '../../app/widgets.dart';
import '../../domain/models.dart';
import '../../state/app_controller.dart';
import '../status/service_status.dart';
import 'connection_card.dart';
import 'home_card_grid.dart';
import 'home_cards.dart';
import 'home_layout_controls.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  static const _cardSpacing = 16.0;

  HomeLayout? _draft;
  bool _editingLandscape = false;
  bool _saving = false;
  final _gridKey = GlobalKey();
  EdgeDraggingAutoScroller? _autoScroller;
  HomeCard? _dragging;
  Offset? _dragPosition;
  Offset? _lastReorderPosition;
  bool _awaitingDragLayout = false;

  String _label(HomeCard card) => switch (card) {
    HomeCard.connection => '连接与出口信息',
    HomeCard.splitMode => '规则模式',
    HomeCard.traffic => '实时流量',
    HomeCard.subscription => '订阅用量',
    HomeCard.services => '服务状态',
    HomeCard.activity => '最近活动',
  };

  Future<void> _edit(AppController controller, bool landscape) async {
    final draft = _draft;
    if (draft == null) {
      final saved = landscape
          ? controller.settings.homeDesktop
          : controller.settings.homeMobile;
      setState(() {
        _editingLandscape = landscape;
        _draft = HomeLayout(order: saved.order, hidden: saved.hidden);
      });
      return;
    }
    _stopDrag();
    setState(() => _saving = true);
    try {
      await controller.saveHomeLayout(draft, desktop: _editingLandscape);
      if (mounted) setState(() => _draft = null);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('首页布局保存失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _stopDrag() {
    _autoScroller?.stopAutoScroll();
    _autoScroller = null;
    _dragPosition = _lastReorderPosition = null;
  }

  @override
  void dispose() {
    _stopDrag();
    super.dispose();
  }

  bool _canEdit(HomeLayout draft) => identical(_draft, draft) && !_saving;

  void _previewReorder(HomeLayout draft) {
    final source = _dragging;
    final position = _dragPosition;
    if (source == null ||
        position == null ||
        !_canEdit(draft) ||
        _awaitingDragLayout) {
      return;
    }
    final slot = HomeCardGrid.slotAt(_gridKey.currentContext, position);
    if (slot == null || !slot.bounds.deflate(8).contains(position)) return;
    final visible = _visibleCards(draft);
    if (slot.index >= visible.length) return;
    final target = visible[slot.index];
    if (target == source) {
      _lastReorderPosition = null;
      return;
    }
    // A waterfall reflow can move a different card under a stationary finger.
    final reorderPosition = _lastReorderPosition;
    if (reorderPosition != null && (position - reorderPosition).distance < 24) {
      return;
    }
    _lastReorderPosition = position;
    final targetIndex = draft.order.indexOf(target);
    // Until the next layout, slot indices still describe the previous order.
    _awaitingDragLayout = true;
    setState(() {
      draft.order.remove(source);
      draft.order.insert(targetIndex, source);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _awaitingDragLayout = false;
    });
  }

  List<HomeCard> _visibleCards(HomeLayout layout) => layout.order
      .where(
        (kind) =>
            kind != HomeCard.connection &&
            !layout.hidden.contains(kind) &&
            (kind != HomeCard.splitMode ||
                AppScope.read(context).showsRuleMode),
      )
      .toList();

  void _startDrag(HomeLayout draft, HomeCard kind, ScrollableState scrollable) {
    if (!_canEdit(draft) || _dragging != null) return;
    setState(() => _dragging = kind);
    _autoScroller = EdgeDraggingAutoScroller(
      scrollable,
      velocityScalar: 8,
      onScrollViewScrolled: () {
        if (mounted) _previewReorder(draft);
      },
    );
  }

  void _updateDrag(HomeLayout draft, HomeCard kind, Offset position) {
    if (_dragging != kind) return;
    _dragPosition = position;
    _previewReorder(draft);
    _autoScroller?.startAutoScrollIfNecessary(
      Rect.fromCenter(center: position, width: 1, height: 64),
    );
  }

  void _endDrag(HomeCard kind) {
    if (!mounted || _dragging != kind) return;
    _stopDrag();
    setState(() => _dragging = null);
  }

  Future<void> _addCard(HomeLayout draft) async {
    final showsRuleMode = AppScope.read(context).showsRuleMode;
    final available = draft.order
        .where(
          (kind) =>
              draft.hidden.contains(kind) &&
              (kind != HomeCard.splitMode || showsRuleMode),
        )
        .toList();
    final selected = await showAppSheet<HomeCard>(
      context: context,
      title: '添加卡片',
      emptyLabel: '所有卡片均已添加',
      options: [
        for (final kind in available)
          (value: kind, icon: Icons.add_rounded, label: _label(kind)),
      ],
    );
    if (!mounted || selected == null || !_canEdit(draft)) return;
    setState(() {
      draft.hidden.remove(selected);
      draft.order
        ..remove(selected)
        ..add(selected);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final showLiveTraffic = TickerMode.valuesOf(context).enabled;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final draft = _draft;
    final layout =
        draft ??
        (landscape
            ? controller.settings.homeDesktop
            : controller.settings.homeMobile);
    Widget card(HomeCard kind, {bool keyed = true}) => KeyedSubtree(
      key: keyed ? ValueKey(kind) : null,
      child: switch (kind) {
        HomeCard.connection => ConnectionCard(
          controller: controller,
          hasNodes: controller.hasNodes,
        ),
        HomeCard.splitMode => HomeSplitModeCard(controller: controller),
        HomeCard.traffic =>
          showLiveTraffic
              ? ValueListenableBuilder<int>(
                  valueListenable: controller.liveTick,
                  builder: (context, _, _) =>
                      HomeTrafficCard(controller: controller),
                )
              : HomeTrafficCard(controller: controller),
        HomeCard.subscription => HomeSubscriptionCard(controller: controller),
        HomeCard.services => ServiceStatusCard(controller: controller),
        HomeCard.activity => HomeActivityCard(controller: controller),
      },
    );
    final visible = _visibleCards(layout);
    final canEdit = !_saving && _dragging == null;
    return PageFrame(
      title: draft == null ? '首页' : '编辑首页',
      wrapHeader: true,
      bottomPadding: 20,
      actions: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (draft == null)
            _NetworkTakeoverActions(controller: controller)
          else
            HeaderIconButton(
              icon: Icons.close_rounded,
              tooltip: '取消编辑',
              onPressed: !canEdit
                  ? null
                  : () {
                      _stopDrag();
                      setState(() => _draft = null);
                    },
            ),
          const SizedBox(width: 8),
          HeaderIconButton(
            icon: _draft == null ? Icons.edit_outlined : Icons.check_rounded,
            tooltip: _draft == null ? '编辑首页' : '完成编辑',
            active: _draft != null,
            onPressed: canEdit ? () => _edit(controller, landscape) : null,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: _cardSpacing,
        children: [
          card(HomeCard.connection),
          if (visible.isNotEmpty || draft != null)
            HomeCardGrid(
              key: _gridKey,
              columns: landscape ? 2 : 1,
              spacing: _cardSpacing,
              animationVsync:
                  draft != null && !MediaQuery.disableAnimationsOf(context)
                  ? this
                  : null,
              children: [
                for (final kind in visible)
                  if (draft == null)
                    card(kind)
                  else
                    EditableHomeCard(
                      key: ValueKey(kind),
                      kind: kind,
                      label: _label(kind),
                      enabled: canEdit,
                      dragging: _dragging == kind,
                      onRemove: () => setState(() => draft.hidden.add(kind)),
                      onDragStarted: (scrollable) =>
                          _startDrag(draft, kind, scrollable),
                      onDragUpdate: (position) =>
                          _updateDrag(draft, kind, position),
                      onDragEnd: () => _endDrag(kind),
                      child: card(kind, keyed: false),
                    ),
                if (draft != null)
                  AddHomeCardButton(
                    key: const ValueKey('add-home-card'),
                    onPressed: canEdit ? () => _addCard(draft) : null,
                  ),
              ],
            ),
        ],
      ),
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
    final enabled = controller.canChangeTakeover;
    final tunSwitch = _CompactSwitch(
      icon: controller.isAndroid ? Icons.vpn_key_rounded : Icons.lan_outlined,
      label: controller.isAndroid ? 'VPN' : 'TUN',
      value: controller.tunManagedByConfig
          ? controller.running && controller.usesTun
          : controller.tunTakeoverEnabled,
      enabled: enabled && !controller.tunManagedByConfig,
      onChanged: (value) => controller.setTun(value),
    );
    final items = <Widget>[
      if (controller.tunManagedByConfig)
        Tooltip(message: '由配置中的入站设置控制', child: tunSwitch)
      else
        tunSwitch,
      if (controller.supportsSystemProxy)
        _CompactSwitch(
          icon: Icons.language_rounded,
          label: '系统代理',
          value: controller.settings.systemProxyEnabled,
          enabled: enabled,
          onChanged: (value) => controller.setSystemProxy(value),
        ),
    ];
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
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
      onTap: enabled ? toggle : null,
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
