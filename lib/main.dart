import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'app/theme.dart';
import 'state/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _registerLicenses();
  runApp(const NekoProxyBootstrap());
}

void _registerLicenses() {
  LicenseRegistry.addLicense(() async* {
    final gpl = await rootBundle.loadString('LICENSE');
    yield LicenseEntryWithLineBreaks(const ['NekoProxy', 'GNU General Public License v3'], gpl);
    final notices = await rootBundle.loadString('third_party/THIRD_PARTY_NOTICES.md');
    yield LicenseEntryWithLineBreaks(const ['NekoProxy third-party notices'], notices);
    final wintun = await rootBundle.loadString('third_party/wintun-LICENSE.txt');
    yield LicenseEntryWithLineBreaks(const ['Wintun'], wintun);
  });
}

class NekoProxyBootstrap extends StatefulWidget {
  const NekoProxyBootstrap({super.key});

  @override
  State<NekoProxyBootstrap> createState() => _NekoProxyBootstrapState();
}

class _NekoProxyBootstrapState extends State<NekoProxyBootstrap> {
  late final AppController _controller = AppController();
  Window? _window;
  ListenerId? _windowListener;
  tray.TrayIcon? _trayIcon;
  bool _ready = false;
  bool _exiting = false;
  Object? _fatal;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      // Native window changes can synchronously notify Flutter of new metrics.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_bootstrap());
      });
    } else {
      unawaited(_bootstrap());
    }
  }

  Future<void> _bootstrap() async {
    try {
      if (Platform.isWindows) {
        _setupWindow();
      }
      await _controller.initialize();
      if (!mounted) return;
      if (Platform.isWindows) {
        _setupTray();
      }
      setState(() => _ready = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _fatal = e);
    }
  }

  void _setupWindow() {
    if (_window != null) return;
    final window = WindowManager.instance.getCurrent();
    if (window == null) {
      throw StateError('无法获取 NekoProxy 窗口');
    }
    _window = window;
    try {
      window
        ..titleBarStyle = TitleBarStyle.normal
        ..title = 'NekoProxy'
        ..minimumSize = const Size(780, 580).toNative()
        ..setSize(const Size(1240, 840).toNative(), false)
        ..center();
      _windowListener = window.addListener(_onWindowEvent);
      _showWindow();
    } catch (_) {
      _disposeWindow();
      rethrow;
    }
  }

  void _setupTray() {
    tray.TrayIcon? icon;
    tray.Image? image;
    tray.Menu? menu;
    try {
      icon = tray.TrayIcon.create();
      image = tray.ImageAsset.fromAsset('assets/icons/app_icon.png');
      menu = tray.Menu.create();
      if (icon == null || image == null || menu == null) {
        throw StateError('无法创建托盘图标或菜单');
      }
      _addTrayMenuItem(menu, '打开 NekoProxy', _showWindow);
      _addTrayMenuItem(menu, '连接 / 断开', _controller.toggleConnection);
      menu.addSeparator();
      _addTrayMenuItem(menu, '退出', _exitApplication);
      icon
        ..icon = image
        ..setTooltip('NekoProxy')
        ..setContextMenu(menu)
        ..setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked)
        ..addListener((event) {
          if (event is tray.TrayIconClickedEvent) _showWindow();
        });
      if (!icon.setVisible(true)) {
        throw StateError('无法显示托盘图标');
      }
      _trayIcon = icon;
    } catch (e) {
      icon?.dispose();
      debugPrint('Tray is unavailable: $e');
    } finally {
      // The tray icon retains the attached image and menu.
      image?.dispose();
      menu?.dispose();
    }
  }

  void _addTrayMenuItem(
    tray.Menu menu,
    String label,
    FutureOr<void> Function() onClick,
  ) {
    final item = tray.MenuItem.createWithLabelAndType(
      label,
      tray.MenuItemType.normal,
    );
    if (item == null) throw StateError('无法创建托盘菜单项 $label');
    try {
      item.addListener((event) async {
        if (event is tray.MenuItemClickedEvent) await onClick();
      });
      menu.addItem(item);
    } finally {
      item.dispose();
    }
  }

  void _showWindow() {
    final window = _window;
    if (window == null) return;
    if (window.isMinimized) window.restore();
    window.show();
    window.focus();
  }

  Future<void> _exitApplication() async {
    if (_exiting) return;
    _exiting = true;
    await _controller.shutdownForExit();
    if (Platform.isWindows) {
      try {
        _disposeTray();
      } catch (e) {
        debugPrint('Could not dispose the tray icon: $e');
      }
      try {
        _disposeWindow(close: true);
      } catch (e) {
        debugPrint('Could not close the window: $e');
      }
    }
    exit(0);
  }

  void _onWindowEvent(WindowEvent event) {
    if (event is! WindowCloseRequestedEvent) return;
    if (!event.request.cancel() || _exiting) return;
    if (_ready && _trayIcon != null && _controller.settings.minimizeToTray) {
      _window?.hide();
    } else {
      unawaited(_exitApplication());
    }
  }

  void _disposeTray() {
    final icon = _trayIcon;
    _trayIcon = null;
    icon?.dispose();
  }

  void _disposeWindow({bool close = false}) {
    final window = _window;
    final listener = _windowListener;
    _window = null;
    _windowListener = null;
    if (window == null) return;
    try {
      if (listener != null) window.removeListener(listener);
      if (close) window.close();
    } finally {
      window.dispose();
    }
  }

  @override
  void dispose() {
    _disposeTray();
    _disposeWindow();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_fatal != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.light, const Color(0xFF0E7490)),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline_rounded, size: 48),
                  const SizedBox(height: 16),
                  const Text('NekoProxy 启动失败', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  SelectableText('$_fatal', textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () {
                      setState(() => _fatal = null);
                      unawaited(_bootstrap());
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (!_ready) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.light, const Color(0xFF0E7490)),
        darkTheme: buildAppTheme(Brightness.dark, const Color(0xFF0E7490)),
        home: const _SplashScreen(),
      );
    }
    return NekoProxyApp(controller: _controller);
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.surface, scheme.primaryContainer.withValues(alpha: 0.5), scheme.surface],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 82,
                height: 82,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [scheme.primary, scheme.tertiary],
                  ),
                ),
                child: Icon(Icons.shield_moon_outlined, size: 42, color: scheme.onPrimary),
              ),
              const SizedBox(height: 20),
              Text('NekoProxy', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text('正在准备 sing-box…',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 22),
              SizedBox(
                width: 120,
                child: LinearProgressIndicator(
                  borderRadius: BorderRadius.circular(6),
                  minHeight: 4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
