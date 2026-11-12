import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/app_scope.dart';
import '../../app/widgets.dart';
import 'app_update_card.dart';

const _injectedVersion = String.fromEnvironment('NEKO_VERSION');
const _injectedCoreVersion = String.fromEnvironment('NEKO_CORE_VERSION');

String _coreLabel(String tag) {
  final version = tag.startsWith('v') ? tag.substring(1) : tag;
  return version.isEmpty ? 'sing-box' : 'sing-box $version';
}

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, this.coreVersion = _injectedCoreVersion});

  /// The bundled sing-box release tag injected by the build scripts.
  final String coreVersion;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final _package = _injectedVersion.isEmpty
      ? PackageInfo.fromPlatform()
      : null;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _package,
      builder: (context, snapshot) {
        final package = snapshot.data;
        final version = _injectedVersion.isNotEmpty
            ? _injectedVersion
            : package == null
            ? null
            : '${package.version} (${package.buildNumber})';
        return _buildPage(
          context,
          version,
          _injectedVersion.isNotEmpty ? _injectedVersion : package?.version,
        );
      },
    );
  }

  Widget _buildPage(
    BuildContext context,
    String? version,
    String? updateVersion,
  ) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('关于 NekoProxy')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(17),
                  child: Image.asset(
                    'assets/icons/app_icon.png',
                    width: 92,
                    height: 92,
                    excludeFromSemantics: true,
                  ),
                ),
                const SizedBox(height: 16),
                Text('NekoProxy', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(
                  version == null
                      ? 'Android / Windows'
                      : '版本 $version · Android / Windows',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                if (updateVersion != null &&
                    context.getInheritedWidgetOfExactType<AppScope>() !=
                        null) ...[
                  AppUpdateCard(currentVersion: updateVersion),
                  const SizedBox(height: 14),
                ],
                SectionCard(
                  title: '技术组件',
                  icon: Icons.memory_rounded,
                  child: Column(
                    children: [
                      KeyValueRow(
                        label: '代理核心',
                        value: _coreLabel(widget.coreVersion),
                        expandValue: true,
                      ),
                      const KeyValueRow(
                        label: '界面',
                        value: 'Flutter · Material 3',
                        expandValue: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                SectionCard(
                  title: '开源协议',
                  icon: Icons.code_rounded,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    children: [
                      Text(
                        'GPL-3.0-or-later',
                        style: theme.textTheme.bodyMedium,
                      ),
                      TextButton.icon(
                        onPressed: () => showLicensePage(
                          context: context,
                          applicationName: 'NekoProxy',
                          applicationVersion: version,
                        ),
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('查看开源许可证'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
