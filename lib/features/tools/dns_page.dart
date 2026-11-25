import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../app/header_fade.dart';
import '../../app/widgets.dart';
import '../../state/app_controller.dart';

class DnsPage extends StatefulWidget {
  const DnsPage({super.key});

  @override
  State<DnsPage> createState() => _DnsPageState();
}

class _DnsPageState extends State<DnsPage> {
  late final TextEditingController _direct;
  late final TextEditingController _proxy;
  late final TextEditingController _timeout;
  String? _strategy;
  bool _routing = true;
  bool _sniff = true;
  bool _reverseMapping = true;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final settings = AppScope.read(context).settings.dnsOrDefault;
    _direct = TextEditingController(text: settings.directServer);
    _proxy = TextEditingController(text: settings.proxyServer);
    _timeout = TextEditingController(text: settings.timeout);
    _strategy = settings.strategy;
    _routing = settings.dnsRouting;
    _sniff = settings.sniff;
    _reverseMapping = settings.reverseMapping;
  }

  @override
  void dispose() {
    _direct.dispose();
    _proxy.dispose();
    _timeout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    return HeaderScaffold(
      title: const Text('DNS'),
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
                  title: '解析服务器',
                  icon: Icons.travel_explore_rounded,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _direct,
                        decoration: const InputDecoration(labelText: '直连 DNS'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _proxy,
                        decoration: const InputDecoration(labelText: '代理 DNS'),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _strategy,
                        decoration: const InputDecoration(labelText: '域名解析策略'),
                        items: const [
                          DropdownMenuItem(
                            value: 'prefer_ipv4',
                            child: Text('优先 IPv4'),
                          ),
                          DropdownMenuItem(
                            value: 'prefer_ipv6',
                            child: Text('优先 IPv6'),
                          ),
                          DropdownMenuItem(
                            value: 'ipv4_only',
                            child: Text('仅 IPv4'),
                          ),
                          DropdownMenuItem(
                            value: 'ipv6_only',
                            child: Text('仅 IPv6'),
                          ),
                        ],
                        onChanged: (value) => setState(() => _strategy = value),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _timeout,
                        decoration: const InputDecoration(labelText: '单次查询超时'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: '行为',
                  icon: Icons.settings_suggest_outlined,
                  child: Column(
                    children: [
                      SwitchRow(
                        title: 'DNS 分流',
                        value: _routing,
                        onChanged: (value) => setState(() => _routing = value),
                      ),
                      SwitchRow(
                        title: '协议嗅探',
                        value: _sniff,
                        onChanged: (value) => setState(() => _sniff = value),
                      ),
                      SwitchRow(
                        title: 'DNS 反向映射',
                        value: _reverseMapping,
                        onChanged: (value) =>
                            setState(() => _reverseMapping = value),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton.icon(
                    onPressed: controller.busy ? null : () => _save(controller),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存并应用'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _save(AppController controller) async {
    final direct = _direct.text.trim();
    final proxy = _proxy.text.trim();
    if (direct.toLowerCase().contains('fakeip') ||
        proxy.toLowerCase().contains('fakeip')) {
      _showError(context, 'DNS 地址不能使用 FakeIP');
      return;
    }
    if (direct.isEmpty || proxy.isEmpty) {
      _showError(context, 'DNS 地址不能为空');
      return;
    }
    if (_strategy == null) {
      _showError(context, '请选择解析策略');
      return;
    }
    await controller.updateDns(
      (dns) => dns
        ..directServer = direct
        ..proxyServer = proxy
        ..strategy = _strategy!
        ..timeout = _timeout.text.trim()
        ..dnsRouting = _routing
        ..sniff = _sniff
        ..reverseMapping = _reverseMapping,
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('DNS 设置已应用')));
    }
  }

  void _showError(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
