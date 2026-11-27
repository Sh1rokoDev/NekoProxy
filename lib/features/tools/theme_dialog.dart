import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
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
      icon: Icons.settings_brightness_outlined,
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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final scale = _scaleDraft ?? settings.uiScalePercent;
    const divider = Divider(height: 1);

    return Dialog(
      alignment: Alignment.center,
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      constraints: const BoxConstraints(maxWidth: 376),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text('主题', style: theme.textTheme.titleLarge),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
            divider,
            _ThemeSetting(
              label: '深浅模式',
              control: _buildModeControl(settings.theme),
            ),
            divider,
            _ThemeSetting(
              label: '强调色',
              control: Wrap(
                alignment: WrapAlignment.center,
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
            ),
            divider,
            _ThemeSetting(
              label: '界面缩放',
              control: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      label: '界面缩放',
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
                            : (value) =>
                                  setState(() => _scaleDraft = value.round()),
                        onChangeEnd: (value) =>
                            _save(uiScalePercent: value.round()),
                      ),
                    ),
                  ),
                  Text('$scale%'),
                ],
              ),
            ),
            if (_saveFailed)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    '主题设置保存失败，请重试。',
                    style: TextStyle(color: colors.error),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeControl(ThemePreference selected) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final fontSize =
            Theme.of(context).textTheme.labelMedium?.fontSize ?? 12;
        final textSize = MediaQuery.textScalerOf(context).scale(fontSize);
        final width = constraints.maxWidth;
        final segmentHeight = math.max(42.0, textSize * 1.4 + 8);
        // Reserve room in each segment for the longest label, icon and padding.
        const iconAndPaddingWidth = 15.0 + 4.0 + 12.0;
        final horizontal =
            width >=
            (textSize * 4 + iconAndPaddingWidth) * _modeOptions.length + 8;
        return SlidingSegmentedControl<ThemePreference>(
          width: width,
          height: horizontal
              ? segmentHeight
              : segmentHeight * _modeOptions.length + 8,
          axis: horizontal ? Axis.horizontal : Axis.vertical,
          segments: _modeOptions,
          selected: selected,
          onChanged: _saving ? null : (mode) => _save(theme: mode),
        );
      },
    );
  }
}

class _ThemeSetting extends StatelessWidget {
  const _ThemeSetting({required this.label, required this.control});

  final String label;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: OverflowBar(
        alignment: MainAxisAlignment.spaceBetween,
        overflowAlignment: OverflowBarAlignment.start,
        spacing: 12,
        overflowSpacing: 6,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          SizedBox(width: 264, child: control),
        ],
      ),
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
    final outline = Theme.of(context).colorScheme.onSurfaceVariant;
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
            width: 48,
            height: 48,
            child: Center(
              child: Container(
                width: 36,
                height: 36,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: selected
                      ? Border.all(color: outline, width: 1.5)
                      : null,
                ),
                child: Ink(
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                  child: selected
                      ? const Icon(
                          Icons.check_rounded,
                          color: Colors.white,
                          size: 16,
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
