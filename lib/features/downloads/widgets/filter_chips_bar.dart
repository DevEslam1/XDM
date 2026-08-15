import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../../core/app_theme.dart';
import '../../../../core/utils/localization.dart';
import '../../../../core/utils/responsive.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';
import '../provider/download_provider.dart';

Color getActiveFilterColor(DownloadProvider provider, bool isDark) {
  final catFilters = provider.categoryFilters;
  if (catFilters.isNotEmpty) {
    final cat = catFilters.first.toLowerCase();
    return switch (cat) {
      'video' => isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
      'audio' => isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
      'document' => isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan,
      'archive' => isDark ? AppTheme.neonOrange : AppTheme.lightNeonOrange,
      'apk' => isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
      _ => isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
    };
  }

  final status = provider.statusFilter;
  return switch (status) {
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
            final activeFilters = p.categoryFilters;
            // FIX-P3: Only tally per-category counts when a category filter is
            // active (that is the only consumer). Avoids a full-task scan on
            // every progress tick when the filter list is empty.
            final counts = <String, int>{};
            if (activeFilters.isNotEmpty) {
              for (final task in p.tasks) {
                if (isHistory &&
                    task.status != DownloadStatus.completed &&
                    task.status != DownloadStatus.failed) {
                  continue;
                }
                final cat = task.category.toLowerCase();
                counts[cat] = (counts[cat] ?? 0) + 1;
              }
            }
            return _FilterState(
              activeFilter: p.statusFilter,
              categoryFilters: activeFilters.toList(),
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
                            padding: const EdgeInsetsDirectional.only(end: 8.0),
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

                // ── Status filter standalone buttons ──
                _StatusFilterButtons(
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
// Standalone filter buttons matching Settings tab button design
// ─────────────────────────────────────────────────────────────────────────────
class _StatusFilterButtons extends StatelessWidget {
  final List<String> filters;
  final String activeFilter;
  final bool isDark;
  final bool vibration;
  final bool classicUi;
  final bool glow;

  const _StatusFilterButtons({
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

  IconData _iconForFilter(String filter) {
    return switch (filter) {
      'All' => Icons.space_dashboard_rounded,
      'Downloading' => Icons.arrow_downward_rounded,
      'Completed' => Icons.check_circle_outline_rounded,
      'Failed' => Icons.error_outline_rounded,
      'Paused' => Icons.pause_circle_outline_rounded,
      'Scheduled' => Icons.schedule_rounded,
      'Torrents' => Icons.grain_rounded,
      _ => Icons.filter_alt_rounded,
    };
  }

  String _labelFor(BuildContext context, String filter) {
    return switch (filter) {
      'All' => L10n.of(context, 'filter_all').toUpperCase(),
      'Downloading' => L10n.of(context, 'stats_downloading').toUpperCase(),
      'Completed' => L10n.of(context, 'stats_completed_short').toUpperCase(),
      'Failed' => L10n.of(context, 'stats_failed_short').toUpperCase(),
      'Paused' => L10n.of(context, 'stats_paused_short').toUpperCase(),
      'Scheduled' => L10n.of(context, 'add_download_schedule').toUpperCase(),
      'Torrents' => L10n.of(context, 'filter_torrents').toUpperCase(),
      _ => filter.toUpperCase(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final isScrollable = filters.length > 3;

    if (isScrollable) {
      return SizedBox(
        height: 38,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: filters.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) => _buildButton(context, filters[i]),
        ),
      );
    }

    return Row(
      children: [
        for (int i = 0; i < filters.length; i++) ...[
          Expanded(child: _buildButton(context, filters[i])),
          if (i < filters.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }

  Widget _buildButton(BuildContext context, String filter) {
    final selected = activeFilter == filter;
    final color = _colorForFilter(filter);
    final icon = _iconForFilter(filter);
    final label = _labelFor(context, filter);

    final bgColor = selected
        ? color
        : (classicUi
            ? (isDark ? AppTheme.surface : AppTheme.lightSurface)
            : (isDark
                ? AppTheme.surface.withValues(alpha: 0.40)
                : AppTheme.lightSurface.withValues(alpha: 0.40)));

    final textColor = selected
        ? AppTheme.inkOn(color)
        : (isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary);

    final iconColor = selected ? textColor : color;

    final borderColor =
        selected ? color : color.withValues(alpha: isDark ? 0.30 : 0.35);

    final shadows = (selected && glow && !classicUi)
        ? [
            BoxShadow(
              color: color.withValues(alpha: isDark ? 0.35 : 0.20),
              blurRadius: 10,
              spreadRadius: 0,
              offset: const Offset(0, 2),
            ),
          ]
        : <BoxShadow>[];

    final Widget buttonContent = Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 1.0),
        boxShadow: shadows,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 15, color: iconColor),
          const SizedBox(width: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: textColor,
              fontFamily: 'Space Grotesk',
              fontSize: responsiveFontSize(context, 11),
              fontWeight: selected ? FontWeight.bold : FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      label: 'Filter: $label',
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            if (vibration) HapticFeedback.selectionClick();
            context.read<DownloadProvider>().setStatusFilter(filter);
          },
          borderRadius: BorderRadius.circular(10),
          child: buttonContent,
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
    final bgColor = classicUi
        ? color.withValues(alpha: isDark ? 0.15 : 0.12)
        : color.withValues(alpha: isDark ? 0.20 : 0.16);

    final borderColor = color.withValues(alpha: isDark ? 0.45 : 0.35);

    final Widget chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: 1.0),
        boxShadow: (glow && !classicUi)
            ? [
                BoxShadow(
                  color: color.withValues(alpha: isDark ? 0.20 : 0.10),
                  blurRadius: 8,
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
              fontSize: 11,
              fontWeight: FontWeight.bold,
              fontFamily: 'Space Grotesk',
            ),
          ),
          const SizedBox(width: 4),
          Semantics(
            button: true,
            label: 'Remove category filter',
            child: GestureDetector(
              onTap: onRemove,
              behavior: HitTestBehavior.opaque,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: Icon(Icons.close_rounded, size: 14, color: color),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      label: 'Remove filter: $label',
      child: chip,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// State holder for Selector
// ─────────────────────────────────────────────────────────────────────────────
class _FilterState {
  final String activeFilter;
  final List<String> categoryFilters;
  final Map<String, int> categoryCounts;

  const _FilterState({
    required this.activeFilter,
    required this.categoryFilters,
    required this.categoryCounts,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _FilterState &&
          runtimeType == other.runtimeType &&
          activeFilter == other.activeFilter &&
          _listEquals(categoryFilters, other.categoryFilters) &&
          _mapEquals(categoryCounts, other.categoryCounts);

  @override
  int get hashCode =>
      activeFilter.hashCode ^
      Object.hashAll(categoryFilters) ^
      Object.hashAll(categoryCounts.entries);

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
}
