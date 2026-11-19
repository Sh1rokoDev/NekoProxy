import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/app/theme.dart';
import 'package:nekoproxy/features/tools/log_text.dart';

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
}
