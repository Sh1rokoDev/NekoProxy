import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../app/widgets.dart';
import '../../services/windows_startup.dart';
import '../../state/app_controller.dart';
import 'about_page.dart';
import 'advanced_page.dart';
import 'backup_page.dart';
import 'config_page.dart';
import 'connections_page.dart';
import 'dns_page.dart';
import 'ingress_page.dart';
import 'logs_page.dart';
import 'rule_sets_page.dart';
import 'theme_dialog.dart';

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    return PageFrame(
      title: '更多',
      actions: HeaderIconButton(
        icon: Icons.palette_outlined,
        label: '主题',
        tooltip: '主题设置',
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => const ThemeDialog(),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionCard(
            title: '常规',
            icon: Icons.tune_rounded,
            child: Column(
              children: [
                SwitchRow(
                  title: '启动时自动连接',
                  icon: Icons.play_circle_outline_rounded,
                  value: controller.settings.autoConnect,
                  onChanged: (value) async {
                    controller.settings.autoConnect = value;
                    await controller.saveSettings();
                  },
                ),
                if (controller.isAndroid)
                  SwitchRow(
                    title: '获取 CPU 唤醒锁',
                    icon: Icons.memory_rounded,
                    value: controller.settings.cpuWakeLockEnabled,
                    onChanged: controller.setCpuWakeLockEnabled,
                  ),
                if (Platform.isWindows)
                  SwitchRow(
                    title: '开机启动',
                    icon: Icons.login_rounded,
                    value: controller.settings.startAtLogin,
                    onChanged: (value) async {
                      await _setLaunchAtStartup(context, controller, value);
                    },
                  ),
                if (Platform.isWindows)
                  SwitchRow(
                    title: '关闭窗口时最小化到托盘',
                    icon: Icons.move_to_inbox_rounded,
                    value: controller.settings.minimizeToTray,
                    onChanged: (value) async {
                      controller.settings.minimizeToTray = value;
                      await controller.saveSettings();
                    },
                  ),
                SwitchRow(
                  title: '规则集自动更新',
                  icon: Icons.rule_folder_outlined,
                  value: controller.settings.ruleSetAutoUpdate,
                  onChanged: (value) async {
                    controller.settings.ruleSetAutoUpdate = value;
                    await controller.saveSettings();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: '网络',
            icon: Icons.router_outlined,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Column(
              children: [
                _ToolTile(
                  icon: Icons.dns_outlined,
                  title: 'DNS',
                  onTap: () => _push(context, const DnsPage()),
                ),
                _ToolTile(
                  icon: Icons.lan_outlined,
                  title: '本地监听与 TUN',
                  onTap: () => _push(context, const IngressPage()),
                ),
                _ToolTile(
                  icon: Icons.tune_rounded,
                  title: '运行参数',
                  onTap: () => _push(context, const AdvancedPage()),
                ),
                _ToolTile(
                  icon: Icons.shield_outlined,
                  title: '规则集',
                  onTap: () => _push(context, const RuleSetsPage()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: '诊断',
            icon: Icons.monitor_heart_outlined,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Column(
              children: [
                _ToolTile(
                  icon: Icons.swap_vert_rounded,
                  title: '当前连接',
                  onTap: () => _push(context, const ConnectionsPage()),
                ),
                _ToolTile(
                  icon: Icons.receipt_long_outlined,
                  title: '运行日志',
                  onTap: () => _push(context, const LogsPage()),
                ),
                _ToolTile(
                  icon: Icons.data_object_rounded,
                  title: '高级配置',
                  onTap: () => _push(context, const ConfigPage()),
                ),
                _ToolTile(
                  icon: Icons.backup_outlined,
                  title: '备份与恢复',
                  onTap: () => _push(context, const BackupPage()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            padding: const EdgeInsets.all(8),
            child: _ToolTile(
              icon: Icons.info_outline_rounded,
              title: '关于 NekoProxy',
              onTap: () => _push(context, const AboutPage()),
            ),
          ),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  Future<void> _setLaunchAtStartup(
    BuildContext context,
    AppController controller,
    bool value,
  ) async {
    try {
      WindowsStartup.setEnabled(value);
      controller.settings.startAtLogin = value;
      await controller.saveSettings();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('设置开机启动失败：$e')));
      }
    }
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, size: 20),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}
