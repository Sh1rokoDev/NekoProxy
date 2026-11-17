import 'dart:math';

import 'package:flutter/material.dart';

import '../../domain/wireguard_profile.dart';

class WireGuardProfileEditor extends StatefulWidget {
  const WireGuardProfileEditor({
    super.key,
    this.profile,
    this.configuration,
    this.raw = false,
    required this.groupId,
  });

  final WireGuardProfile? profile;
  final WireGuardConfig? configuration;
  final bool raw;
  final String groupId;

  @override
  State<WireGuardProfileEditor> createState() => _WireGuardProfileEditorState();
}

class _WireGuardProfileEditorState extends State<WireGuardProfileEditor> {
  late final _name = TextEditingController(text: widget.profile?.name);
  late final _raw = TextEditingController(text: widget.profile?.configuration);
  late final _interface = _Fields({
    'PrivateKey': widget.configuration?.options['private_key'],
    'Address': (widget.configuration?.options['address'] as List<String>?)
        ?.join(', '),
    'DNS': [
      ...?widget.configuration?.dns,
      ...?widget.configuration?.searchDomains,
    ].join(', '),
    'ListenPort': widget.configuration?.options['listen_port'],
    'MTU': widget.configuration?.options['mtu'],
  });
  late final _peers = [
    for (final peer in widget.configuration?.peers ?? const [])
      _Fields({
        'PublicKey': peer['public_key'],
        'PresharedKey': peer['pre_shared_key'],
        'Endpoint': _endpoint(peer['address'] as String, peer['port']),
        'AllowedIPs': (peer['allowed_ips'] as List<String>).join(', '),
        'PersistentKeepalive': peer['persistent_keepalive_interval'],
      }),
    if (widget.configuration == null) _newPeer(),
  ];
  bool _showRaw = false;
  String? _error;

  static _Fields _newPeer() => _Fields({
    'PublicKey': null,
    'PresharedKey': null,
    'Endpoint': null,
    'AllowedIPs': null,
    'PersistentKeepalive': null,
  });

  static String _endpoint(String host, Object? port) =>
      host.contains(':') ? '[$host]:$port' : '$host:$port';

  @override
  void dispose() {
    _name.dispose();
    if (widget.raw) {
      _raw.dispose();
    } else {
      _interface.dispose();
      for (final peer in _peers) {
        peer.dispose();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.raw
          ? '编写 WireGuard .conf'
          : widget.profile == null
          ? '创建 WireGuard 节点'
          : '编辑 WireGuard 节点',
    ),
    scrollable: true,
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '名称'),
          ),
          if (widget.raw)
            if (widget.profile == null || _showRaw)
              TextField(
                controller: _raw,
                keyboardType: TextInputType.multiline,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 6,
                maxLines: 12,
                decoration: const InputDecoration(
                  labelText: 'WireGuard 配置',
                  hintText: '[Interface]\n…\n\n[Peer]\n…',
                ),
              )
            else
              TextButton(
                onPressed: () => setState(() => _showRaw = true),
                child: const Text('显示并编辑配置（含密钥）'),
              )
          else ...[
            const Text('本地接口'),
            _interface.input('PrivateKey', '私钥', secret: true),
            _interface.input('Address', '本地地址（Address）', hint: '10.0.0.2/24'),
            _interface.input('DNS', 'DNS（选填）'),
            _interface.input('ListenPort', '监听端口（选填）', numeric: true),
            _interface.input('MTU', 'MTU（选填）', numeric: true),
            for (final (index, peer) in _peers.indexed)
              Column(
                key: ObjectKey(peer),
                spacing: 12,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('对端 ${index + 1}')),
                      if (_peers.length > 1)
                        IconButton(
                          tooltip: '移除对端 ${index + 1}',
                          onPressed: () {
                            setState(() => _peers.remove(peer));
                            WidgetsBinding.instance.addPostFrameCallback(
                              (_) => peer.dispose(),
                            );
                          },
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                    ],
                  ),
                  peer.input('PublicKey', '对端公钥'),
                  peer.input('PresharedKey', '预共享密钥（选填）', secret: true),
                  peer.input(
                    'Endpoint',
                    '对端地址（Endpoint）',
                    hint: 'vpn.example.com:51820',
                  ),
                  peer.input(
                    'AllowedIPs',
                    '允许的网段（AllowedIPs）',
                    hint: '0.0.0.0/0, ::/0',
                  ),
                  peer.input('PersistentKeepalive', '保活秒数（选填）', numeric: true),
                ],
              ),
            OutlinedButton.icon(
              onPressed: () => setState(() => _peers.add(_newPeer())),
              icon: const Icon(Icons.add),
              label: const Text('添加对端'),
            ),
          ],
          if (_error case final error?)
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存节点')),
    ],
  );

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入配置名称。');
      return;
    }
    try {
      final configuration = widget.raw
          ? _raw.text
          : (_interface.write('Interface') +
                _peers.map((peer) => peer.write('Peer')).join());
      final profile = WireGuardProfile(
        id:
            widget.profile?.id ??
            '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 31)}',
        name: name,
        configuration: configuration,
        groupId: widget.groupId,
      );
      profile.parse();
      Navigator.pop(context, profile);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }
}

class _Fields {
  _Fields(Map<String, Object?> values)
    : _controllers = {
        for (final entry in values.entries)
          entry.key: TextEditingController(text: entry.value?.toString()),
      };

  final Map<String, TextEditingController> _controllers;

  TextField input(
    String field,
    String label, {
    String? hint,
    bool secret = false,
    bool numeric = false,
  }) => TextField(
    controller: _controllers[field],
    obscureText: secret,
    autocorrect: false,
    enableSuggestions: false,
    keyboardType: numeric ? TextInputType.number : TextInputType.text,
    decoration: InputDecoration(labelText: label, hintText: hint),
  );

  String write(String section) {
    final output = StringBuffer('[$section]\n');
    for (final entry in _controllers.entries) {
      final value = entry.value.text.trim();
      if (value.isEmpty) continue;
      if (value.contains(RegExp(r'[\r\n#]'))) {
        throw FormatException('${entry.key} 包含无效字符。');
      }
      output.writeln('${entry.key} = $value');
    }
    return (output..writeln()).toString();
  }

  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
  }
}
