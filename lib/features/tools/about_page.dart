import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/header_fade.dart';
import '../../services/app_update_service.dart' show repository;
import 'app_update_card.dart';

const _injectedVersion = String.fromEnvironment('NEKO_VERSION');

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static const _maxContentWidth = 720.0;
  static const _twoColumnMinWidth = 540.0;
  static const _horizontalIdentityMinWidth = 204.0;

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
          version,
          _injectedVersion.isNotEmpty ? _injectedVersion : package?.version,
        );
      },
    );
  }

  Widget _buildPage(String? version, String? updateVersion) {
    return HeaderScaffold(
      title: const Text('关于'),
      maxContentWidth: _maxContentWidth,
      body: (headerInset) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, headerInset, 24, 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxContentWidth),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final scheme = Theme.of(context).colorScheme;
                final dividerColor =
                    DividerTheme.of(context).color ?? scheme.outlineVariant;
                final textScaler = MediaQuery.textScalerOf(context);
                final width = constraints.maxWidth;
                final wide = width >= textScaler.scale(_twoColumnMinWidth);
                final stackIdentity =
                    wide ||
                    width < textScaler.scale(_horizontalIdentityMinWidth);
                const columnGap = 24.0;
                const identityFlex = 5;
                const linksFlex = 7;
                // Keep the updater mounted when the window switches layouts.
                final columns = Flex(
                  direction: wide ? Axis.horizontal : Axis.vertical,
                  crossAxisAlignment: wide
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.stretch,
                  spacing: columnGap,
                  children: [
                    Flexible(
                      flex: wide ? identityFlex : 0,
                      fit: FlexFit.tight,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 24,
                        children: [
                          _AppIdentity(
                            direction: stackIdentity
                                ? Axis.vertical
                                : Axis.horizontal,
                            iconSize: wide ? 108 : 68,
                          ),
                          if (version != null && updateVersion != null)
                            AppUpdateCard(
                              currentVersion: updateVersion,
                              versionLabel: version,
                            ),
                        ],
                      ),
                    ),
                    Flexible(
                      flex: wide ? linksFlex : 0,
                      fit: FlexFit.tight,
                      child: Padding(
                        padding: wide
                            ? const EdgeInsetsDirectional.only(start: columnGap)
                            : EdgeInsets.zero,
                        child: _ProjectLinks(version: version),
                      ),
                    ),
                  ],
                );
                return Stack(
                  fit: StackFit.passthrough,
                  children: [
                    columns,
                    if (wide)
                      PositionedDirectional(
                        start:
                            columnGap +
                            (width - columnGap) *
                                identityFlex /
                                (identityFlex + linksFlex),
                        top: 0,
                        bottom: 0,
                        width: 1,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            key: const ValueKey('about-column-divider'),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  dividerColor.withValues(alpha: 0),
                                  dividerColor,
                                  dividerColor,
                                  dividerColor.withValues(alpha: 0),
                                ],
                                stops: const [0, 0.08, 0.92, 1],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _AppIdentity extends StatelessWidget {
  const _AppIdentity({required this.direction, required this.iconSize});

  final Axis direction;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stacked = direction == Axis.vertical;
    return Flex(
      direction: direction,
      crossAxisAlignment: stacked
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      spacing: 16,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(iconSize / 4),
          child: Image.asset(
            'assets/icons/app_icon.png',
            width: iconSize,
            height: iconSize,
            excludeFromSemantics: true,
          ),
        ),
        Flexible(
          flex: stacked ? 0 : 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text('NekoProxy', style: theme.textTheme.headlineSmall),
              Text(
                'sing-box 图形客户端',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                'Android · Windows · Linux',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProjectLinks extends StatelessWidget {
  const _ProjectLinks({required this.version});

  final String? version;

  static const _links = [
    (label: '发布记录', path: '/releases', icon: Icons.sell_outlined),
    (label: '问题反馈', path: '/issues', icon: Icons.chat_bubble_outline_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card.outlined(
      margin: EdgeInsets.zero,
      semanticContainer: false,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            tileColor: scheme.surfaceContainer,
            minTileHeight: 76,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Text(
              'GitHub 仓库',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            subtitle: Text(repository, style: theme.textTheme.titleMedium),
            trailing: Icon(
              Icons.arrow_outward_rounded,
              size: 18,
              color: scheme.primary,
            ),
            onTap: () => _openLink(context, ''),
          ),
          for (final link in _links) ...[
            const Divider(),
            ListTile(
              title: Text(link.label),
              leading: Icon(link.icon, size: 18),
              trailing: const Icon(Icons.arrow_outward_rounded, size: 18),
              minTileHeight: 48,
              onTap: () => _openLink(context, link.path),
            ),
          ],
          const Divider(),
          Tooltip(
            message: '查看开源许可证',
            child: ListTile(
              title: const Text('GPL-3.0-or-later'),
              leading: const Icon(Icons.description_outlined, size: 18),
              trailing: const Icon(Icons.chevron_right_rounded, size: 18),
              minTileHeight: 48,
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'NekoProxy',
                applicationVersion: version,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openLink(BuildContext context, String path) async {
    final uri = Uri.https('github.com', '/$repository$path');
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } on Exception catch (error) {
      debugPrint('Could not open GitHub link: $error');
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法打开链接，请稍后重试。')));
    }
  }
}
