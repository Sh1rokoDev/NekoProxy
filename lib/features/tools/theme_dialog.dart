import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../app/dialogs.dart';
import '../../app/sliding_segmented_control.dart';
import '../../domain/models.dart';

class ThemeDialog extends StatefulWidget {
  const ThemeDialog({super.key});

  @override
  State<ThemeDialog> createState() => _ThemeDialogState();
}

class _ThemeDialogState extends State<ThemeDialog> {
  static const _accents = [
    (name: '青', color: Color(0xFF0E7490)),
    (name: '蓝', color: Color(0xFF2563EB)),
    (name: '紫', color: Color(0xFF7C3AED)),
    (name: '红', color: Color(0xFFDC2626)),
    (name: '绿', color: Color(0xFF15803D)),
  ];

  static const _modeOptions = [
    SlidingSegmentOption(
      value: ThemePreference.system,
      label: '跟随系统',
      icon: Icons.monitor_outlined,
    ),
    SlidingSegmentOption(
      value: ThemePreference.light,
      label: '浅色',
      icon: Icons.light_mode_outlined,
    ),
    SlidingSegmentOption(
      value: ThemePreference.dark,
      label: '深色',
      icon: Icons.dark_mode_outlined,
    ),
  ];

  bool _saving = false;
  bool _saveFailed = false;
  int? _scaleDraft;

  Future<void> _save({
    ThemePreference? theme,
    int? seedColor,
    int? uiScalePercent,
  }) async {
    if (_saving) return;
    final controller = AppScope.read(context);
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    var failed = false;
    try {
      await controller.setAppearance(
        theme: theme,
        seedColor: seedColor,
        uiScalePercent: uiScalePercent,
      );
    } catch (error) {
      debugPrint('Theme settings save failed: ${error.runtimeType}');
      failed = true;
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveFailed = failed;
          _scaleDraft = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    final colors = Theme.of(context).colorScheme;
    final scale = _scaleDraft ?? settings.uiScalePercent;
    return AppDialog(
      title: const Text('主题'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Semantics(
            label: '深浅模式',
            container: true,
            child: _buildModeControl(settings.theme),
          ),
          OverflowBar(
            alignment: MainAxisAlignment.spaceBetween,
            spacing: 12,
            overflowSpacing: 4,
            children: [
              const Text('强调色'),
              Wrap(
                children: [
                  for (final option in _accents)
                    _AccentSwatch(
                      name: option.name,
                      color: option.color,
                      selected: settings.seedColor == option.color.toARGB32(),
                      onTap: _saving
                          ? null
                          : () => _save(seedColor: option.color.toARGB32()),
                    ),
                ],
              ),
            ],
          ),
          _buildScaleControl(scale),
          if (_saveFailed)
            Semantics(
              liveRegion: true,
              child: Text(
                '主题设置保存失败，请重试。',
                style: TextStyle(color: colors.error),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildScaleControl(int scale) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        const label = '界面缩放';
        const controlWidth = 220.0;
        const gap = 12.0;
        final fontSize = DefaultTextStyle.of(context).style.fontSize ?? 14;
        final labelWidth =
            MediaQuery.textScalerOf(context).scale(fontSize) * label.length;
        final narrow = constraints.maxWidth < controlWidth + gap + labelWidth;
        return OverflowBar(
          alignment: MainAxisAlignment.spaceBetween,
          spacing: gap,
          overflowSpacing: 4,
          children: [
            const Text(label),
            SizedBox(
              width: narrow ? constraints.maxWidth : controlWidth,
              child: Row(
                spacing: 10,
                children: [
                  Expanded(
                    // Keep the Slider's value-indicator portal in the dialog
                    // subtree during its entrance (Flutter #190357).
                    child: Overlay.wrap(
                      alwaysSizeToContent: true,
                      clipBehavior: Clip.none,
                      child: Semantics(
                        label: '界面缩放',
                        child: SliderTheme(
                          data: theme.sliderTheme.copyWith(
                            trackHeight: 4,
                            trackShape: const RoundedRectSliderTrackShape(),
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7,
                              elevation: 0,
                              pressedElevation: 0,
                            ),
                            tickMarkShape: SliderTickMarkShape.noTickMark,
                            inactiveTrackColor: colors.outlineVariant,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: Slider(
                            value: scale.toDouble(),
                            min: AppSettings.minUiScalePercent.toDouble(),
                            max: AppSettings.maxUiScalePercent.toDouble(),
                            divisions:
                                (AppSettings.maxUiScalePercent -
                                    AppSettings.minUiScalePercent) ~/
                                AppSettings.uiScaleStep,
                            semanticFormatterCallback: (value) =>
                                '${value.round()}%',
                            onChanged: _saving
                                ? null
                                : (value) => setState(
                                    () => _scaleDraft = value.round(),
                                  ),
                            onChangeEnd: (value) =>
                                _save(uiScalePercent: value.round()),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Text(
                    '$scale%',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildModeControl(ThemePreference selected) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        final fontSize = theme.textTheme.labelMedium?.fontSize ?? 12;
        final textSize = MediaQuery.textScalerOf(context).scale(fontSize);
        final width = constraints.maxWidth;
        final segmentHeight = math.max(48.0, textSize * 1.4 + 8);
        // Reserve room in each segment for the longest label, icon and padding.
        const iconAndPaddingWidth = 15.0 + 4.0 + 12.0;
        final horizontal =
            width >=
            (textSize * 4 + iconAndPaddingWidth) * _modeOptions.length + 8;
        return Theme(
          data: theme.copyWith(
            colorScheme: colors.copyWith(
              surfaceContainerHigh: colors.surfaceContainer,
              secondaryContainer: colors.surfaceContainerLow,
              onSecondaryContainer: colors.primary,
            ),
          ),
          child: SlidingSegmentedControl<ThemePreference>(
            width: width,
            height: horizontal
                ? segmentHeight
                : segmentHeight * _modeOptions.length + 8,
            axis: horizontal ? Axis.horizontal : Axis.vertical,
            cornerRadius: 10,
            segments: _modeOptions,
            selected: selected,
            onChanged: _saving ? null : (mode) => _save(theme: mode),
          ),
        );
      },
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.onSurface;
    return Tooltip(
      message: name,
      excludeFromSemantics: true,
      child: Semantics(
        label: name,
        button: true,
        selected: selected,
        child: InkResponse(
          onTap: onTap,
          containedInkWell: true,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: selected
                      ? Border.all(color: outline, width: 1.5)
                      : null,
                ),
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                  child: selected
                      ? const Icon(
                          Icons.check_rounded,
                          color: Colors.white,
                          size: 14,
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
