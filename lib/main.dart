import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'app/theme.dart';
import 'data/app_storage.dart';
import 'state/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _registerLicenses();
  runApp(const NekoProxyBootstrap());
}

void _registerLicenses() {
  LicenseRegistry.addLicense(() async* {
    final gpl = await rootBundle.loadString('LICENSE');
    yield LicenseEntryWithLineBreaks(const [
      'NekoProxy',
      'GNU General Public License v3',
    ], gpl);
    final notices = await rootBundle.loadString(
      'third_party/THIRD_PARTY_NOTICES.md',
    );
    yield LicenseEntryWithLineBreaks(const [
      'NekoProxy third-party notices',
    ], notices);
    final wintun = await rootBundle.loadString(
      'third_party/wintun-LICENSE.txt',
    );
    yield LicenseEntryWithLineBreaks(const ['Wintun'], wintun);
  });
}

class NekoProxyBootstrap extends StatefulWidget {
  const NekoProxyBootstrap({super.key});

  @override
  State<NekoProxyBootstrap> createState() => _NekoProxyBootstrapState();
}

class _NekoProxyBootstrapState extends State<NekoProxyBootstrap>
    with WidgetsBindingObserver {
  late final AppController _controller = AppController();
  Window? _window;
  Color? _windowBackground;
  ListenerId? _windowListener;
  tray.TrayIcon? _trayIcon;
  bool _ready = false;
  bool _exiting = false;
  Object? _fatal;
  Future<void>? _startup;
  RandomAccessFile? _linuxInstanceLock;
  static const _linuxLifecycle = MethodChannel('nekoproxy/linux_lifecycle');
  static const _androidLauncherIcon = MethodChannel('nekoproxy/launcher_icon');

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _controller.appearanceTick.addListener(_syncAndroidLauncherIcon);
    }
    if (Platform.isWindows) {
      WidgetsBinding.instance.addObserver(this);
      _controller.appearanceTick.addListener(_syncWindowBackground);
      // Native window changes can synchronously notify Flutter of new metrics.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startBootstrap();
      });
    } else {
      if (Platform.isLinux) {
        _linuxLifecycle.setMethodCallHandler((call) async {
          if (call.method == 'close') await _exitApplication();
        });
      }
      _startBootstrap();
    }
  }

  void _startBootstrap() {
    if (_startup != null || _ready || _exiting) return;
    _startup = _bootstrap().whenComplete(() => _startup = null);
    unawaited(_startup);
  }

  Future<void> _syncAndroidLauncherIcon() async {
    try {
      await _androidLauncherIcon.invokeMethod<void>(
        'setTheme',
        _controller.settings.theme.name,
      );
    } on PlatformException catch (error) {
      debugPrint('Could not update the Android launcher icon: ${error.code}');
    }
  }

  Future<AppPaths> _linuxAppPaths() async {
    final paths = await AppPaths.resolve();
    if (_linuxInstanceLock != null) return paths;
    final lock = await File('${paths.base.path}/.instance.lock')
        .open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } on FileSystemException {
      await lock.close();
      throw StateError('当前用户已有一个 NekoProxy 实例正在运行。');
    }
    if (mounted && !_exiting) {
      _linuxInstanceLock = lock;
    } else {
      await lock.close();
    }
    return paths;
  }

  Future<void> _bootstrap() async {
    try {
      if (Platform.isWindows) {
        _setupWindow();
      }
      final paths = Platform.isLinux ? await _linuxAppPaths() : null;
      if (!mounted || _exiting) return;
      await _controller.initialize(appPaths: paths);
      if (!mounted || _exiting) return;
      if (Platform.isWindows) {
        _setupTray();
      }
      setState(() => _ready = true);
      _syncWindowBackground();
    } catch (e) {
      if (!mounted || _exiting) return;
      setState(() {
        _ready = false;
        _fatal = e;
      });
      _syncWindowBackground();
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
      _syncWindowBackground();
      window
        ..titleBarStyle = TitleBarStyle.normal
        ..title = 'NekoProxy'
        ..minimumSize = const Size(480, 420).toNative()
        ..setSize(const Size(1240, 840).toNative(), false)
        ..center();
      _windowListener = window.addListener(_onWindowEvent);
      _showWindow();
    } catch (_) {
      _disposeWindow();
      rethrow;
    }
  }

  Brightness _effectiveBrightness(Brightness platformBrightness) =>
      switch (appThemeMode(_controller.settings.theme)) {
        ThemeMode.system => platformBrightness,
        ThemeMode.light => Brightness.light,
        ThemeMode.dark => Brightness.dark,
      };

  @override
  void didChangePlatformBrightness() => _syncWindowBackground();

  void _syncWindowBackground() {
    final window = _window;
    if (window == null) return;
    final brightness = _effectiveBrightness(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
    final background = _fatal != null
        ? appSurfaceColor(Brightness.light)
        : _ready
        ? appSurfaceColor(brightness)
        : _splashBackground(brightness);
    if (background == _windowBackground) return;
    // The parent fills the exposed area while Flutter's resize is pending.
    try {
      window.backgroundColor = background.toNative();
      _windowBackground = background;
    } catch (error) {
      debugPrint(
        'Could not update the window background: ${error.runtimeType}',
      );
    }
  }

  void _setupTray() {
    tray.TrayIcon? icon;
    tray.Image? image;
    tray.Menu? menu;
    try {
      icon = tray.TrayIcon.create();
      image = tray.ImageAsset.fromAsset('assets/icons/tray_icon.png');
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
    try {
      await Future.wait([?_startup, _controller.shutdownForExit()]);
    } catch (error) {
      debugPrint('Could not complete runtime shutdown: ${error.runtimeType}');
    }
    if (Platform.isLinux) {
      final lock = _linuxInstanceLock;
      _linuxInstanceLock = null;
      try {
        await lock?.close();
      } on FileSystemException catch (error) {
        debugPrint('Could not close the instance lock: ${error.osError}');
      }
    } else if (Platform.isWindows) {
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
    _windowBackground = null;
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
    if (Platform.isAndroid) {
      _controller.appearanceTick.removeListener(_syncAndroidLauncherIcon);
    }
    if (Platform.isWindows) {
      WidgetsBinding.instance.removeObserver(this);
      _controller.appearanceTick.removeListener(_syncWindowBackground);
    }
    if (Platform.isLinux) {
      _linuxLifecycle.setMethodCallHandler(null);
      unawaited(_linuxInstanceLock?.close());
    }
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
                  const Text(
                    'NekoProxy 启动失败',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  SelectableText('$_fatal', textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () {
                      setState(() => _fatal = null);
                      _syncWindowBackground();
                      _startBootstrap();
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
      return ValueListenableBuilder<int>(
        valueListenable: _controller.appearanceTick,
        builder: (context, _, _) {
          final settings = _controller.settings;
          return _SplashScreen(
            brightness: _effectiveBrightness(
              MediaQuery.platformBrightnessOf(context),
            ),
            seed: Color(settings.seedColor),
          );
        },
      );
    }
    return NekoProxyApp(controller: _controller, onExit: _exitApplication);
  }
}

Color _splashBackground(Brightness brightness) =>
    brightness == Brightness.dark ? Colors.black : Colors.white;

class _SplashScreen extends StatelessWidget {
  const _SplashScreen({required this.brightness, required this.seed});

  final Brightness brightness;
  final Color seed;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    // The preparation screen does not need routing or the full app theme.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: _splashBackground(brightness),
        child: Center(
          child: SizedBox(
            width: 120,
            child: LinearProgressIndicator(
              color: colors.primary,
              backgroundColor: colors.secondaryContainer,
              borderRadius: BorderRadius.circular(6),
              minHeight: 4,
              semanticsLabel: '正在准备 NekoProxy',
            ),
          ),
        ),
      ),
    );
  }
}
