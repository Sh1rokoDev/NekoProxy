import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/header_fade.dart';
import '../../app/widgets.dart';
import '../../domain/models.dart';
import '../../state/app_controller.dart';

class IngressPage extends StatefulWidget {
  const IngressPage({super.key});

  @override
  State<IngressPage> createState() => _IngressPageState();
}

class _IngressPageState extends State<IngressPage> {
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _mtu;
  bool _allowLan = false;
  bool _ipv6 = true;
  bool _strictRoute = true;
  bool _autoRoute = true;
  bool _bypassLan = true;
  StackMode _stack = StackMode.mixed;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final controller = AppScope.read(context);
    final inbound = controller.settings.inboundOrDefault;
    final tun = controller.settings.tunOrDefault;
    _port = TextEditingController(text: '${inbound.localPort}');
    _username = TextEditingController(text: inbound.authUsername);
    _password = TextEditingController(text: inbound.authPassword);
    _mtu = TextEditingController(text: '${tun.mtu}');
    _allowLan = inbound.allowLan;
    _stack = tun.stack;
    _ipv6 = tun.ipv6;
    _strictRoute = tun.strictRoute;
    _autoRoute = tun.autoRoute;
    _bypassLan = tun.bypassLan;
  }

  @override
  void dispose() {
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _mtu.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final theme = Theme.of(context);
    final windows = Platform.isWindows;
    return HeaderScaffold(
      title: const Text('本地监听与 TUN'),
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
                  title: '本地代理',
                  icon: Icons.settings_ethernet_rounded,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '混合端口（HTTP + SOCKS）',
                        ),
                      ),
                      SwitchRow(
                        title: '允许局域网访问',
                        value: _allowLan,
                        onChanged: (value) => setState(() => _allowLan = value),
                      ),
                      const Divider(height: 24),
                      Text('入站认证（可选）', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _username,
                              decoration: const InputDecoration(
                                labelText: '用户名',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: _password,
                              obscureText: true,
                              decoration: const InputDecoration(
                                labelText: '密码',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: windows ? 'TUN 模式' : 'VPN / TUN',
                  icon: Icons.shield_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _mtu,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'MTU'),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<StackMode>(
                        initialValue: _stack,
                        decoration: const InputDecoration(labelText: '网络栈'),
                        items: const [
                          DropdownMenuItem(
                            value: StackMode.mixed,
                            child: Text('mixed'),
                          ),
                          DropdownMenuItem(
                            value: StackMode.system,
                            child: Text('system'),
                          ),
                          DropdownMenuItem(
                            value: StackMode.gvisor,
                            child: Text('gvisor'),
                          ),
                        ],
                        onChanged: windows
                            ? null
                            : (value) =>
                                  setState(() => _stack = value ?? _stack),
                      ),
                      SwitchRow(
                        title: '启用 IPv6',
                        value: _ipv6,
                        onChanged: (value) => setState(() => _ipv6 = value),
                      ),
                      SwitchRow(
                        title: '自动路由',
                        value: _autoRoute,
                        onChanged: (value) =>
                            setState(() => _autoRoute = value),
                      ),
                      SwitchRow(
                        title: '严格路由',
                        value: _strictRoute,
                        onChanged: (value) =>
                            setState(() => _strictRoute = value),
                      ),
                      SwitchRow(
                        title: '局域网直连',
                        value: _bypassLan,
                        onChanged: (value) =>
                            setState(() => _bypassLan = value),
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
    final port = int.tryParse(_port.text.trim()) ?? 0;
    final mtu = int.tryParse(_mtu.text.trim()) ?? 0;
    if (port < 1 || port > 65535) {
      _error('端口必须在 1–65535 之间');
      return;
    }
    if (mtu < 1280 || mtu > 9000) {
      _error('MTU 必须在 1280–9000 之间');
      return;
    }
    if ((_username.text.isEmpty) != (_password.text.isEmpty)) {
      _error('用户名和密码需要同时填写，或同时留空');
      return;
    }
    controller.settings.inbound = InboundSettings(
      localPort: port,
      allowLan: _allowLan,
      authUsername: _username.text,
      authPassword: _password.text,
      sniff: controller.settings.inboundOrDefault.sniff,
    );
    controller.settings.tun = TunSettings(
      mtu: mtu,
      stack: _stack,
      ipv6: _ipv6,
      strictRoute: _strictRoute,
      autoRoute: _autoRoute,
      bypassLan: _bypassLan,
    );
    await controller.saveSettings();
    if (controller.running) await controller.restartCore();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('监听与 TUN 设置已应用')));
    }
  }

  void _error(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
