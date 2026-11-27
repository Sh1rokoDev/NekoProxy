import 'package:material_ui/material_ui.dart';

import '../../app/header_fade.dart';
import '../../app/widgets.dart';
import '../../domain/models.dart';
import '../../state/app_controller.dart';

class OutboundSettingsPage extends StatefulWidget {
  const OutboundSettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<OutboundSettingsPage> createState() => _OutboundSettingsPageState();
}

class _OutboundSettingsPageState extends State<OutboundSettingsPage> {
  String? _error;

  Future<void> _toggle(bool value) async {
    setState(() => _error = null);
    try {
      await widget.controller.setChainProxyEnabled(value);
    } on Exception catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, child) {
      final controller = widget.controller;
      final enabled = controller.chainProxyEnabled;
      final profile = controller.snapshot.wireGuardProfile;
      final mode = controller.outboundMode;
      final automatic = controller.settings.selectionMode == SelectionMode.auto;
      final proxy = automatic
          ? controller.running
                ? controller.reportedNode?.name
                : null
          : controller.currentNode?.name ??
                controller.snapshot.allNodes.firstOrNull?.name;
      final proxyLabel = automatic
          ? proxy == null
                ? '自动选择'
                : '自动选择 · $proxy'
          : proxy ?? '未选择';
      final custom = controller.snapshot.useCustomConfig;
      return HeaderScaffold(
        title: const Text('高级'),
        body: (inset) => ListView(
          padding: EdgeInsets.fromLTRB(24, inset, 24, 24),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: HeaderScaffold.defaultContentWidth,
                ),
                child: SectionCard(
                  title: '链式代理',
                  icon: Icons.route_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 12,
                    children: [
                      Material(
                        type: MaterialType.transparency,
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('启用链式代理'),
                          value: enabled,
                          onChanged:
                              custom ||
                                  controller.busy ||
                                  controller.changingWireGuard
                              ? null
                              : _toggle,
                        ),
                      ),
                      if (custom)
                        const Text('当前出站由完整自定义配置接管。')
                      else ...[
                        if (mode != OutboundMode.proxy)
                          _Stage(
                            icon: Icons.vpn_key_outlined,
                            title: enabled ? '第一级 · WireGuard' : 'WireGuard',
                            node: profile?.name ?? '未选择',
                          ),
                        if (enabled)
                          const Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Icon(Icons.arrow_downward, size: 18),
                          ),
                        if (mode != OutboundMode.wireGuard)
                          _Stage(
                            icon: Icons.dns_outlined,
                            title: enabled ? '第二级 · sing-box' : 'sing-box',
                            node: proxyLabel,
                          ),
                        if (profile == null || !controller.hasNodes)
                          const Text('请在节点页选择 WireGuard 和 sing-box 节点。'),
                      ],
                      if (_error case final error?)
                        Text(
                          error,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _Stage extends StatelessWidget {
  const _Stage({required this.icon, required this.title, required this.node});
  final IconData icon;
  final String title;
  final String node;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(node),
    contentPadding: EdgeInsets.zero,
  );
}
