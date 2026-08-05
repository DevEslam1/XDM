import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../../core/app_theme.dart';
import '../../../../core/utils/localization.dart';
import '../../../../core/utils/responsive.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';
import '../provider/download_provider.dart';

class FilterChipsBar extends StatelessWidget {
  final bool isHistory;
  const FilterChipsBar({super.key, this.isHistory = false});

  @override
  Widget build(BuildContext context) {
    return Selector<SettingsProvider,
        ({bool isDark, bool vibration, bool classicUi, bool glow})>(
      selector: (_, s) => (
        isDark: s.isDarkMode,
        vibration: s.vibration,
        classicUi: s.classicUi,
        glow: s.enableGlow,
      ),
      builder: (context, settings, _) {
        final isDark = settings.isDark;
        final vibration = settings.vibration;
        final classicUi = settings.classicUi;
        final glow = settings.glow;

        final filters = isHistory
            ? ['All', 'Completed', 'Failed']
            : ['All', 'Downloading', 'Paused', 'Scheduled', 'Torrents'];

        return Selector<DownloadProvider, _FilterState>(
          selector: (_, p) {
            final counts = <String, int>{};
            for (final task in p.tasks) {
              if (isHistory &&
                  task.status != DownloadStatus.completed &&
                  task.status != DownloadStatus.failed) {
                continue;
              }
              final cat = task.category.toLowerCase();
              counts[cat] = (counts[cat] ?? 0) + 1;
            }
            return _FilterState(
              activeFilter: p.statusFilter,
              categoryFilters: p.categoryFilters.toList(),
              categoryCounts: counts,
            );
          },
          builder: (context, state, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Active category filter chips (removable) ──
                if (state.categoryFilters.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      height: 32,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: state.categoryFilters.length,
                        itemBuilder: (context, index) {
                          final category = state.categoryFilters[index];
                          final count =
                              state.categoryCounts[category.toLowerCase()] ?? 0;
                          final catColor = isDark
                              ? AppTheme.neonGreen
                              : AppTheme.lightNeonGreen;
                          return Padding(
                            padding:
                                const EdgeInsetsDirectional.only(end: 8.0),
                            child: _CategoryChip(
                              label:
                                  '${L10n.of(context, 'cat_filter_label')}${category.toUpperCase()} ($count)',
                              color: catColor,
                              isDark: isDark,
                              classicUi: classicUi,
                              glow: glow,
                              onRemove: () {
                                if (vibration) HapticFeedback.lightImpact();
                                context
                                    .read<DownloadProvider>()
                                    .toggleCategoryFilter(category);
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ),

                // ── Status filter segmented pill ──
                _StatusSegmentedBar(
                  filters: filters,
                  activeFilter: state.activeFilter,
                  isDark: isDark,
                  vibration: vibration,
                  classicUi: classicUi,
                  glow: glow,
                ),
              ],
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Segmented bar — glass/neon in modern mode, opaque in classic mode
// ─────────────────────────────────────────────────────────────────────────────
class _StatusSegmentedBar extends StatelessWidget {
  final List<String> filters;
  final String activeFilter;
  final bool isDark;
  final bool vibration;
  final bool classicUi;
  final bool glow;

  const _StatusSegmentedBar({
    required this.filters,
    required this.activeFilter,
    required this.isDark,
    required this.vibration,
    required this.classicUi,
    required this.glow,
  });

  Color _colorForFilter(String filter) {
    return switch (filter) {
      'All' => isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
      'Downloading' => isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
      'Completed' => isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
      'Failed' => isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
      'Paused' => isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
      'Scheduled' => isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
      'Torrents' => isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
      _ => isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
    };
  }

  String _labelFor(BuildContext context, String filter) {
    return switch (filter) {
      'All' => L10n.of(context, 'filter_all').toUpperCase(),
      'Downloading' => L10n.of(context, 'stats_downloading').toUpperCase(),
      'Completed' =>
        L10n.of(context, 'stats_completed_short').toUpperCase(),
      'Failed' => L10n.of(context, 'stats_failed_short').toUpperCase(),
      'Paused' => L10n.of(context, 'stats_paused_short').toUpperCase(),
      'Scheduled' =>
        L10n.of(context, 'add_download_schedule').toUpperCase(),
      'Torrents' => L10n.of(context, 'filter_torrents').toUpperCase(),
      _ => filter.toUpperCase(),
    };
  }

  // The accent color of whichever filter is currently active
  Color get _activeAccent => _colorForFilter(activeFilter);

  @override
  Widget build(BuildContext context) {
    final isScrollable = filters.length > 3;

    // Glass background — transparent in modern, solid in classic
    final bgColor = classicUi
        ? (isDark ? AppTheme.surface : AppTheme.lightSurface)
        : (isDark
            ? AppTheme.surface.withValues(alpha: 0.35)
            : AppTheme.lightSurface.withValues(alpha: 0.35));

    // Border: neon glow on active accent in modern+glow, subtle otherwise
    final borderColor = (!classicUi && glow)
        ? _activeAccent.withValues(alpha: isDark ? 0.50 : 0.40)
        : (isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle);

    // Outer glow shadow only in modern+glow mode
    final shadows = (!classicUi && glow)
        ? [
            BoxShadow(
              color: _activeAccent.withValues(alpha: isDark ? 0.18 : 0.10),
              blurRadius: 14,
              spreadRadius: 1,
            ),
          ]
        : <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.03),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ];

    Widget container = Container(
      height: 40,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 1.0),
        boxShadow: shadows,
      ),
      child: isScrollable
          ? ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 4),
              itemBuilder: (context, i) => _buildSegment(context, filters[i]),
            )
          : Row(
              children: [
                for (int i = 0; i < filters.length; i++) ...[
                  Expanded(child: _buildSegment(context, filters[i])),
                  if (i < filters.length - 1) const SizedBox(width: 4),
                ],
              ],
            ),
    );

    // Wrap with backdrop blur in modern UI mode
    if (!classicUi) {
      container = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: DmxBackdropFilter(
          sigmaX: 14,
          sigmaY: 14,
          child: container,
        ),
      );
    }

    return container;
  }

  Widget _buildSegment(BuildContext context, String filter) {
    final selected = activeFilter == filter;
    final color = _colorForFilter(filter);
    final label = _labelFor(context, filter);

    // Selected fill: solid in classic, slightly translucent in modern
    final fillColor = selected
        ? (classicUi ? color : color.withValues(alpha: isDark ? 0.85 : 0.80))
        : Colors.transparent;

    return GestureDetector(
      onTap: () {
        if (vibration) HapticFeedback.selectionClick();
        context.read<DownloadProvider>().setStatusFilter(filter);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(6),
          // In modern+glow: add a soft inner glow on the selected pill
          boxShadow: (selected && !classicUi && glow)
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.35),
                    blurRadius: 8,
                    spreadRadius: 0,
                  ),
                ]
              : null,
        ),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected
                  ? Colors.white
                  : (isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary),
              fontFamily: 'Space Grotesk',
              fontSize: responsiveFontSize(context, 11),
              fontWeight: selected ? FontWeight.bold : FontWeight.w500,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Category chip — removable active-filter badge
// ─────────────────────────────────────────────────────────────────────────────
class _CategoryChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool isDark;
  final bool classicUi;
  final bool glow;
  final VoidCallback onRemove;

  const _CategoryChip({
    required this.label,
    required this.color,
    required this.isDark,
    required this.classicUi,
    required this.glow,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final bgAlpha = classicUi ? 0.18 : 0.10;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: bgAlpha),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: color.withValues(alpha: classicUi ? 0.35 : 0.55),
          width: 1.0,
        ),
        boxShadow: (!classicUi && glow)
            ? [
                BoxShadow(
                  color: color.withValues(alpha: isDark ? 0.20 : 0.10),
                  blurRadius: 8,
                  spreadRadius: 0,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontFamily: 'Space Grotesk',
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onRemove,
            child: Icon(Icons.close_rounded, size: 14, color: color),
          ),
        ],
      ),
    );

    if (!classicUi) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: DmxBackdropFilter(sigmaX: 12, sigmaY: 12, child: chip),
      );
    }
    return chip;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// State holder
// ─────────────────────────────────────────────────────────────────────────────
class _FilterState {
  final String activeFilter;
  final List<String> categoryFilters;
  final Map<String, int> categoryCounts;

  _FilterState({
    required this.activeFilter,
    required this.categoryFilters,
    required this.categoryCounts,
  });

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _mapEquals(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _FilterState &&
          runtimeType == other.runtimeType &&
          activeFilter == other.activeFilter &&
          _listEquals(categoryFilters, other.categoryFilters) &&
          _mapEquals(categoryCounts, other.categoryCounts);

  @override
  int get hashCode => Object.hash(
        activeFilter,
        Object.hashAll(categoryFilters),
        Object.hashAll(
            categoryCounts.entries.map((e) => Object.hash(e.key, e.value))),
      );
}
