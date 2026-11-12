import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_update_service.dart';

class AppUpdateInstaller {
  const AppUpdateInstaller(this.windowsDataDirectory);

  final Directory windowsDataDirectory;
  static const _android = MethodChannel('nekoproxy/update');

  UpdatePackageKind? get packageKind {
    if (Platform.isAndroid) return UpdatePackageKind.android;
    if (!Platform.isWindows) return null;
    final exe = File(Platform.resolvedExecutable);
    return File.fromUri(exe.parent.uri.resolve('uninstall.exe')).existsSync()
        ? UpdatePackageKind.windowsInstaller
        : UpdatePackageKind.windowsPortable;
  }

  Future<Directory> downloadDirectory() async {
    final base = Platform.isAndroid
        ? await getTemporaryDirectory()
        : windowsDataDirectory;
    return Directory.fromUri(base.uri.resolve('updates/'));
  }

  Future<bool> install(
    AppUpdate update,
    File file, {
    Future<void> Function()? exitApplication,
  }) async {
    switch (update.kind) {
      case UpdatePackageKind.android:
        return await _android.invokeMethod<bool>('installApk', file.path) ??
            false;
      case UpdatePackageKind.windowsInstaller:
        if (exitApplication == null) {
          throw const AppUpdateException('无法安全退出应用并启动安装。');
        }
        await Process.start(
          file.path,
          const ['/WAITFORNEKO'],
          workingDirectory: file.parent.path,
          mode: ProcessStartMode.detached,
        );
        await exitApplication();
        return true;
      case UpdatePackageKind.windowsPortable:
        if (!await launchUrl(
          file.parent.uri,
          mode: LaunchMode.externalApplication,
        )) {
          throw const AppUpdateException('无法打开更新包所在的文件夹。');
        }
        return true;
    }
  }
}
