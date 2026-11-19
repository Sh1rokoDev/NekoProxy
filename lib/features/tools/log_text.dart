import 'package:flutter/material.dart';

class LogText extends StatelessWidget {
  const LogText({super.key, required this.lines});

  final List<String> lines;

  // sing-box emits a full timestamp before the level, an elapsed timestamp
  // after it, or just the level. The connection context and tag are optional.
  static final _prefix = RegExp(
    r'^([+-]\d{4} \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} )?'
    r'(TRACE|DEBUG|INFO|WARN|ERROR|FATAL|PANIC)'
    r'(\[-?\d+\])? '
    r'(\[\d+ \d+(?:ms|\.\d+s|m\d+)\] )?'
    r'([\w/-]+(?:\[[^\]\r\n]*\])?: )?',
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    final timestampStyle = TextStyle(
      color: dark ? const Color(0xFF9DD9A5) : const Color(0xFF2D693E),
      fontWeight: FontWeight.w700,
    );
    final tagStyle = TextStyle(
      color: dark ? const Color(0xFFD1B5F5) : const Color(0xFF70449C),
    );
    final info = dark ? const Color(0xFF82D5E5) : const Color(0xFF006477);
    final warning = dark ? const Color(0xFFFFC66D) : const Color(0xFF894E00);
    final spans = <TextSpan>[];

    for (final (index, line) in lines.indexed) {
      if (index > 0) spans.add(const TextSpan(text: '\n'));
      final match = _prefix.firstMatch(line);
      if (match == null) {
        spans.add(TextSpan(text: line));
        continue;
      }

      final level = match[2];
      final levelColor = switch (level) {
        'INFO' => info,
        'WARN' => warning,
        'ERROR' || 'FATAL' || 'PANIC' => scheme.error,
        _ => scheme.onSurfaceVariant,
      };
      spans.addAll([
        if (match[1] case final timestamp?)
          TextSpan(text: timestamp, style: timestampStyle),
        TextSpan(
          text: level,
          style: TextStyle(color: levelColor, fontWeight: FontWeight.w700),
        ),
        if (match[3] case final elapsedTimestamp?)
          TextSpan(text: elapsedTimestamp, style: timestampStyle),
        TextSpan(text: ' ${match[4] ?? ''}', style: muted),
        if (match[5] case final tag?) TextSpan(text: tag, style: tagStyle),
        TextSpan(text: line.substring(match.end)),
      ]);
    }

    return SelectableText.rich(
      TextSpan(children: spans),
      style: TextStyle(
        color: scheme.onSurface,
        fontFamily: 'monospace',
        fontSize: 12,
        height: 1.55,
      ),
    );
  }
}
