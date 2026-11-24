import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../../core/app_theme.dart';
import '../../../../core/utils/localization.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../shared/design/dmx_tokens.dart';
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

        final filters = isHistory ? _historyFilters : _downloadFilters;

        return Selector<DownloadProvider, _FilterState>(
          selector: (_, p) {
            final activeFilters = p.categoryFilters;
            final categoryCounts = <String, int>{};
            final statusCounts = <String, int>{};
            final now = DateTime.now();

            int allCount = 0;
            int downloadingCount = 0;
            int pausedCount = 0;
            int scheduledCount = 0;
            int torrentsCount = 0;
            int completedCount = 0;
            int failedCount = 0;

            for (final task in p.tasks) {
              final isTaskHistory = task.status == DownloadStatus.completed ||
                  task.status == DownloadStatus.failed;
              if (isHistory) {
                if (!isTaskHistory) continue;
                allCount++;
                if (task.status == DownloadStatus.completed) completedCount++;
                if (task.status == DownloadStatus.failed) failedCount++;
              } else {
                if (isTaskHistory) continue;
                allCount++;
                if (task.status == DownloadStatus.downloading ||
                    task.status == DownloadStatus.queued ||
                    task.status == DownloadStatus.merging) {
                  downloadingCount++;
                }
                if (task.status == DownloadStatus.paused) pausedCount++;
                if (task.status == DownloadStatus.paused &&
                    task.scheduledAt != null &&
                    task.scheduledAt!.isAfter(now)) {
                  scheduledCount++;
                }
                if (task.isTorrent) torrentsCount++;
              }

              if (activeFilters.isNotEmpty) {
                final cat = task.category.toLowerCase();
                categoryCounts[cat] = (categoryCounts[cat] ?? 0) + 1;
              }
            }

            if (isHistory) {
              statusCounts['All'] = allCount;
              statusCounts['Completed'] = completedCount;
              statusCounts['Failed'] = failedCount;
            } else {
              statusCounts['All'] = allCount;
              statusCounts['Downloading'] = downloadingCount;
              statusCounts['Paused'] = pausedCount;
              statusCounts['Scheduled'] = scheduledCount;
              statusCounts['Torrents'] = torrentsCount;
            }

            return _FilterState(
              activeFilter: p.statusFilter,
              categoryFilters: activeFilters.toList(),
              categoryCounts: categoryCounts,
              statusCounts: statusCounts,
            );
          },
          builder: (context, state, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Active category filter pills (removable)
                if (state.categoryFilters.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: DmxTokens.spaceSm),
                    child: SizedBox(
                      height: 34,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        itemCount: state.categoryFilters.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(width: DmxTokens.spaceSm),
                        itemBuilder: (context, index) {
                          final category = state.categoryFilters[index];
                          final count =
                              state.categoryCounts[category.toLowerCase()] ?? 0;
                          final catColor = _colorForCategory(category, isDark);
                          return _CategoryChip(
                            label:
                                '${L10n.of(context, 'cat_filter_label')}${category.toUpperCase()}',
                            count: count,
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
                          );
                        },
                      ),
                    ),
                  ),

                // Status filter pill bar
                _StatusFilterPills(
                  filters: filters,
                  activeFilter: state.activeFilter,
                  statusCounts: state.statusCounts,
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

  static Color _colorForCategory(String category, bool isDark) {
    return switch (category.toLowerCase()) {
      'video' => isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
      'audio' => isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
      'document' => isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan,
      'archive' => isDark ? AppTheme.neonOrange : AppTheme.lightNeonOrange,
      _ => isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
    };
  }

  static const List<String> _historyFilters = ['All', 'Completed', 'Failed'];
  static const List<String> _downloadFilters = [
    'All',
    'Downloading',
    'Paused',
    'Scheduled',
    'Torrents'
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
// Horizontal pill bar with clean active states and count badges
// ─────────────────────────────────────────────────────────────────────────────
class _StatusFilterPills extends StatelessWidget {
  final List<String> filters;
  final String activeFilter;
  final Map<String, int> statusCounts;
  final bool isDark;
  final bool vibration;
  final bool classicUi;
  final bool glow;

  const _StatusFilterPills({
    required this.filters,
    required this.activeFilter,
    required this.statusCounts,
    required this.isDark,
    required this.vibration,
    required this.classicUi,
    required this.glow,
  });

  static const Map<String, IconData> _filterIcons = {
    'All': Icons.space_dashboard_rounded,
    'Downloading': Icons.arrow_downward_rounded,
    'Completed': Icons.check_circle_outline_rounded,
    'Failed': Icons.error_outline_rounded,
    'Paused': Icons.pause_circle_outline_rounded,
    'Scheduled': Icons.schedule_rounded,
    'Torrents': Icons.grain_rounded,
  };

  static const Map<String, String> _filterL10nKeys = {
    'All': 'filter_all',
    'Downloading': 'stats_downloading',
    'Completed': 'stats_completed_short',
    'Failed': 'stats_failed_short',
    'Paused': 'stats_paused_short',
    'Scheduled': 'add_download_schedule',
    'Torrents': 'filter_torrents',
  };

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
    return _filterIcons[filter] ?? Icons.filter_alt_rounded;
  }

  String _labelFor(BuildContext context, String filter) {
    final key = _filterL10nKeys[filter];
    if (key != null) {
      return L10n.of(context, key);
    }
    return filter;
  }

  @override
  Widget build(BuildContext context) {
    final isScrollable = filters.length > 3;
    if (isScrollable) {
      return SizedBox(
        height: 38,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          itemCount: filters.length,
          separatorBuilder: (_, __) => const SizedBox(width: DmxTokens.spaceSm),
          itemBuilder: (context, i) => _buildPill(context, filters[i]),
        ),
      );
    }

    return SizedBox(
      height: 38,
      child: Row(
        children: [
          for (int i = 0; i < filters.length; i++) ...[
            Expanded(child: _buildPill(context, filters[i], expand: true)),
            if (i < filters.length - 1)
              const SizedBox(width: DmxTokens.spaceSm),
          ],
        ],
      ),
    );
  }

  Widget _buildPill(BuildContext context, String filter,
      {bool expand = false}) {
    final selected = activeFilter == filter;
    final color = _colorForFilter(filter);
    final icon = _iconForFilter(filter);
    final label = _labelFor(context, filter);
    final count = statusCounts[filter] ?? 0;

    final inactiveBg = classicUi
        ? (isDark ? AppTheme.surface : AppTheme.lightSurface)
        : (isDark
            ? AppTheme.surface.withValues(alpha: 0.65)
            : AppTheme.lightSurface.withValues(alpha: 0.90));

    final bgColor = selected ? color : inactiveBg;
    final fgColor = selected
        ? AppTheme.inkOn(color)
        : (isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary);
    final iconColor = selected ? fgColor : color.withValues(alpha: 0.9);
    final borderColor = selected
        ? color
        : (isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle);

    final shadows = (selected && glow && !classicUi)
        ? [
            BoxShadow(
              color: color.withValues(alpha: isDark ? 0.28 : 0.18),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ]
        : const <BoxShadow>[];

    final badgeBg = selected
        ? fgColor.withValues(alpha: 0.18)
        : (isDark
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.black.withValues(alpha: 0.06));

    final badgeFg = selected
        ? fgColor
        : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted);

    return Semantics(
      button: true,
      label: count > 0 ? 'Filter: $label ($count)' : 'Filter: $label',
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            if (vibration) HapticFeedback.selectionClick();
            context.read<DownloadProvider>().setStatusFilter(filter);
          },
          borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
          child: AnimatedContainer(
            duration: DmxTokens.animFast,
            curve: DmxTokens.animCurve,
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
              border: Border.all(
                color: borderColor,
                width: selected ? 1.0 : DmxTokens.borderThin,
              ),
              boxShadow: shadows,
            ),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: iconColor),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fgColor,
                      fontFamily: 'Space Grotesk',
                      fontSize: responsiveFontSize(context, 11.5),
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: badgeBg,
                      borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        color: badgeFg,
                        fontFamily: 'Space Grotesk',
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
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
  final int count;
  final Color color;
  final bool isDark;
  final bool classicUi;
  final bool glow;
  final VoidCallback onRemove;

  const _CategoryChip({
    required this.label,
    required this.count,
    required this.color,
    required this.isDark,
    required this.classicUi,
    required this.glow,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = color.withValues(alpha: isDark ? 0.16 : 0.12);
    final borderColor = color.withValues(alpha: isDark ? 0.40 : 0.32);

    return Semantics(
      button: true,
      label: 'Remove filter: $label ($count)',
      child: Container(
        height: 32,
        padding: const EdgeInsetsDirectional.only(start: 10, end: 4),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
          border: Border.all(color: borderColor, width: 0.9),
          boxShadow: (glow && !classicUi)
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: isDark ? 0.16 : 0.08),
                    blurRadius: 8,
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$label ($count)',
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFamily: 'Space Grotesk',
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(width: 4),
            Semantics(
              button: true,
              label: 'Remove category filter',
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onRemove,
                  borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: Icon(Icons.close_rounded, size: 14, color: color),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
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
  final Map<String, int> statusCounts;

  const _FilterState({
    required this.activeFilter,
    required this.categoryFilters,
    required this.categoryCounts,
    required this.statusCounts,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _FilterState &&
          runtimeType == other.runtimeType &&
          activeFilter == other.activeFilter &&
          _listEquals(categoryFilters, other.categoryFilters) &&
          _mapEquals(categoryCounts, other.categoryCounts) &&
          _mapEquals(statusCounts, other.statusCounts);

  @override
  int get hashCode =>
      activeFilter.hashCode ^
      Object.hashAll(categoryFilters) ^
      Object.hashAll(categoryCounts.entries) ^
      Object.hashAll(statusCounts.entries);

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
