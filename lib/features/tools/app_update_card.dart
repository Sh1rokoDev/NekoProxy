import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_scope.dart';
import '../../services/app_update_installer.dart';
import '../../services/app_update_service.dart';

class AppUpdateCard extends StatefulWidget {
  const AppUpdateCard({
    super.key,
    required this.currentVersion,
    required this.versionLabel,
  });

  final String currentVersion;
  final String versionLabel;

  @override
  State<AppUpdateCard> createState() => _AppUpdateCardState();
}

class _AppUpdateCardState extends State<AppUpdateCard> {
  late final _controller = AppScope.read(context);
  late final _installer = AppUpdateInstaller(_controller.paths.base);
  late final _packageKind =
      (Platform.isAndroid || Platform.isWindows) &&
          context.getInheritedWidgetOfExactType<AppScope>() != null
      ? _installer.packageKind
      : null;
  late final _service = _controller.createUpdateService();
  bool _usedService = false;
  bool _busy = false;
  double? _progress;
  AppUpdate? _update;
  File? _downloaded;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_packageKind case final kind?) unawaited(_check(kind));
    });
  }

  @override
  void dispose() {
    if (_usedService) _service.close();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on AppUpdateException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.message ?? '无法打开系统安装程序。');
    } on FileSystemException {
      if (mounted) setState(() => _message = '无法读取或保存更新包，请检查剩余空间和目录权限。');
    } on ProcessException {
      if (mounted) setState(() => _message = '无法启动 Windows 安装程序。');
    } on Exception catch (error) {
      debugPrint('App update failed: $error');
      if (mounted) setState(() => _message = '更新操作失败，请稍后重试。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _check(UpdatePackageKind kind) => _run(() async {
    setState(() {
      _update = null;
      _downloaded = null;
    });
    _usedService = true;
    final update = await _service.check(widget.currentVersion, kind);
    if (!mounted) return;
    setState(() {
      _update = update;
      if (update == null) _message = '没有可用的新版本。';
    });
  });

  Future<void> _download(AppUpdate update) => _run(() async {
    setState(() => _progress = 0);
    _usedService = true;
    final directory = await _installer.downloadDirectory();
    if (!mounted) return;
    final file = await _service.download(
      update,
      directory,
      onProgress: (value) {
        if (mounted &&
            ((_progress ?? 0) * 100).floor() != (value * 100).floor()) {
          setState(() => _progress = value);
        }
      },
    );
    if (!mounted) return;
    setState(() {
      _downloaded = file;
      _message = update.kind == UpdatePackageKind.windowsPortable
          ? '下载并校验完成。退出 NekoProxy 后解压替换程序文件，保留 userdata 目录。'
          : '下载并校验完成，可以安装。';
    });
  });

  Future<void> _install(AppUpdate update, File file) => _run(() async {
    if (!await file.exists()) {
      if (mounted) setState(() => _downloaded = null);
      throw const AppUpdateException('下载文件已不存在，请重新下载。');
    }
    if (!mounted) return;
    final opened = await _installer.install(
      update,
      file,
      exitApplication: AppScope.exitCallback(context),
    );
    if (!mounted) return;
    setState(
      () => _message = opened
          ? (update.kind == UpdatePackageKind.windowsPortable
                ? '退出 NekoProxy 后解压替换程序文件，保留 userdata 目录。'
                : '请在系统安装界面确认更新。')
          : '请允许 NekoProxy 安装未知应用，返回后再次点击「安装更新」。',
    );
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = _packageKind;
    final update = _update;
    final file = _downloaded;
    final progress = _progress;
    final statusStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        OverflowBar(
          alignment: MainAxisAlignment.spaceBetween,
          overflowAlignment: OverflowBarAlignment.start,
          spacing: 12,
          overflowSpacing: 8,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text('当前版本', style: statusStyle),
                Text(widget.versionLabel, style: theme.textTheme.titleLarge),
              ],
            ),
            if (kind != null)
              OutlinedButton(
                onPressed: _busy ? null : () => _check(kind),
                child: const Text('检查更新'),
              ),
          ],
        ),
        if (update != null) Text('新版本：${update.tag}'),
        if (_message case final message?)
          Semantics(liveRegion: true, child: Text(message, style: statusStyle)),
        if (_busy) ...[
          LinearProgressIndicator(value: progress),
          if (progress != null)
            Text(
              progress == 1 ? '正在校验更新包…' : '下载中 ${(progress * 100).floor()}%',
              style: statusStyle,
            ),
        ],
        if (update != null)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        if (!await launchUrl(
                          update.releasePage,
                          mode: LaunchMode.externalApplication,
                        )) {
                          throw const AppUpdateException('无法打开发布说明。');
                        }
                      }),
                child: const Text('发布说明'),
              ),
              FilledButton(
                onPressed: _busy
                    ? null
                    : file == null
                    ? () => _download(update)
                    : () => _install(update, file),
                child: Text(
                  file == null
                      ? '下载更新'
                      : kind == UpdatePackageKind.windowsPortable
                      ? '打开下载位置'
                      : '安装更新',
                ),
              ),
            ],
          ),
      ],
    );
  }
}
