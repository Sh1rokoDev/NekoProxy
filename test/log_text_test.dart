import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/app_scope.dart';
import 'package:nekoproxy/app/theme.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/features/tools/log_text.dart';
import 'package:nekoproxy/features/tools/logs_page.dart';
import 'package:nekoproxy/state/app_controller.dart';

void main() {
  const timestamp = '+0800 2026-11-19 11:37:52 ';
  const lines = [
    '${timestamp}INFO [988338796 3ms] router: permission denied',
    '${timestamp}INFO [988338796 1.23s] inbound/mixed[mixed-in]: connected',
    'WARN[0001] outbound/direct[直连]: retrying',
    'ERROR [42 1m2] dns: lookup failed',
    'FATAL startup failed',
    'PANIC unexpected state',
    'DEBUG router: ERROR is part of the message',
    'TRACE trace message',
    '2026/11/19 11:37:52 worker: ERROR in plain output',
  ];

  for (final brightness in Brightness.values) {
    testWidgets('运行日志在 ${brightness.name} 主题中保留原文并高亮字段', (tester) async {
      final theme = buildAppTheme(brightness, Colors.blue);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(body: LogText(lines: lines)),
        ),
      );

      final log = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(log.textSpan!.toPlainText(), lines.join('\n'));
      final spans = log.textSpan!.children!.cast<TextSpan>();
      TextStyle? styleOf(String text) =>
          spans.firstWhere((span) => span.text == text).style;

      final scheme = theme.colorScheme;
      final dark = brightness == Brightness.dark;
      final timestampColor = dark
          ? const Color(0xFF9DD9A5)
          : const Color(0xFF2D693E);
      final tagColor = dark ? const Color(0xFFD1B5F5) : const Color(0xFF70449C);
      final info = styleOf('INFO')!;
      final warning = styleOf('WARN')!;
      expect(info.fontWeight, FontWeight.w700);
      expect(warning.fontWeight, FontWeight.w700);
      expect({
        info.color,
        warning.color,
        scheme.error,
        timestampColor,
        tagColor,
      }, hasLength(5));
      expect(info.color, isNot(scheme.onSurface));
      expect(warning.color, isNot(scheme.onSurface));
      expect(styleOf(timestamp)?.color, timestampColor);
      expect(styleOf('[0001]')?.color, timestampColor);
      expect(styleOf(timestamp)?.fontWeight, FontWeight.w700);
      expect(styleOf('[0001]')?.fontWeight, FontWeight.w700);
      for (final level in ['ERROR', 'FATAL', 'PANIC']) {
        expect(styleOf(level)?.color, scheme.error);
      }
      for (final metadata in [
        ' [988338796 3ms] ',
        ' [988338796 1.23s] ',
        ' [42 1m2] ',
        'DEBUG',
        'TRACE',
      ]) {
        expect(styleOf(metadata)?.color, scheme.onSurfaceVariant);
      }
      for (final tag in [
        'router: ',
        'inbound/mixed[mixed-in]: ',
        'outbound/direct[直连]: ',
        'dns: ',
      ]) {
        expect(styleOf(tag)?.color, tagColor);
      }
      expect(styleOf('permission denied'), isNull);
      expect(styleOf('ERROR is part of the message'), isNull);
      expect(styleOf(lines.last), isNull);
    });
  }

  testWidgets('轮询按行解码 UTF-8，暂停和翻看历史时保留用户位置', (tester) async {
    final directory = Directory.systemTemp.createTempSync('neko-logs-');
    final paths = AppPaths.forDirectory(directory.path);
    final log = paths.logFile;
    log.parent.createSync();
    final controller = _LogsController()..paths = paths;
    addTearDown(() {
      controller.dispose();
      directory.deleteSync(recursive: true);
    });

    final original = List.generate(100, (index) => 'INFO 历史日志 $index');
    log.writeAsStringSync('${original.join('\n')}\n');
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const LogsPage()),
      ),
    );

    List<String> lines() =>
        tester.widgetList<LogText>(find.byType(LogText)).firstOrNull?.lines ??
        const [];

    Future<void> awaitView(bool Function() condition) async {
      for (var attempt = 0; attempt < 50 && !condition(); attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(condition(), isTrue);
    }

    await awaitView(() => lines().length == original.length);
    expect(lines(), original);
    final scroll = tester.widget<Scrollbar>(find.byType(Scrollbar)).controller!;
    expect(scroll.offset, greaterThan(160));
    scroll.jumpTo(0);
    await tester.pump();

    final bytes = utf8.encode('跨块写入\r\n');
    log.writeAsBytesSync(bytes.take(1).toList(), mode: FileMode.append);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(lines(), original);
    log.writeAsBytesSync(bytes.skip(1).toList(), mode: FileMode.append);
    await tester.pump(const Duration(seconds: 1));
    await awaitView(() => lines().last == '跨块写入');
    expect(lines(), [...original, '跨块写入']);
    expect(scroll.offset, 0);

    await tester.tap(find.byTooltip('暂停'));
    log.writeAsStringSync('INFO 文件已替换\n');
    controller.changed();
    await tester.pump(const Duration(seconds: 2));
    expect(lines().last, '跨块写入');
    await tester.tap(find.byTooltip('继续'));
    await awaitView(() => lines().length == 1);
    expect(lines(), ['INFO 文件已替换']);

    await tester.tap(find.byTooltip('清空文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pump();
    await awaitView(() => lines().isEmpty);
    expect(log.readAsStringSync(), '');

    log.writeAsStringSync('INFO 新日志\n');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    for (var step = 0; step < 4; step++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通控制器通知不会重置日志文件的读取位置', (tester) async {
    final directory = Directory.systemTemp.createTempSync('neko-logs-tick-');
    final paths = AppPaths.forDirectory(directory.path);
    final file = paths.logFile;
    file.parent.createSync();
    file.writeAsStringSync('INFO previous\n');
    final controller = _LogsController()..paths = paths;
    addTearDown(() {
      controller.dispose();
      directory.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const LogsPage()),
      ),
    );
    for (
      var attempt = 0;
      attempt < 50 && find.byType(LogText).evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    final logText = find.byType(LogText);
    expect(tester.widget<LogText>(logText).lines, ['INFO previous']);
    file.writeAsStringSync('INFO replaced\n');
    controller.changed();
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    expect(tester.widget<LogText>(logText).lines, ['INFO previous']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _LogsController extends AppController {
  void changed() => notifyListeners();
}
