import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../../core/app_theme.dart';
import '../../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';
import '../provider/download_provider.dart';

class FilterChipsBar extends StatelessWidget {
  final bool isHistory;
  const FilterChipsBar({super.key, this.isHistory = false});

  @override
  Widget build(BuildContext context) {
    // Selector on isDarkMode so chip colors repaint on theme toggle.
    return Selector<SettingsProvider, bool>(
      selector: (_, s) => s.isDarkMode,
      builder: (context, isDark, _) {
        final glassBg = isDark ? AppTheme.glassBg : AppTheme.lightGlassBg;
        final glassBorder = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
        final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

        final filters = isHistory
            ? ['All', 'Completed', 'Failed']
            : ['All', 'Downloading', 'Paused', 'Scheduled', 'Torrents'];

        return Selector<DownloadProvider, _FilterState>(
          selector: (_, p) {
            final counts = <String, int>{};
            for (final task in p.tasks) {
              if (isHistory && task.status != DownloadStatus.completed && task.status != DownloadStatus.failed) continue;
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
            return SizedBox(
              height: 40,
              child: Row(
                children: [
                  if (state.categoryFilters.isNotEmpty)
                    Expanded(
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: state.categoryFilters.length,
                        itemBuilder: (context, index) {
                          final category = state.categoryFilters[index];
                          final count = state.categoryCounts[category.toLowerCase()] ?? 0;
                          return Padding(
                            padding: const EdgeInsetsDirectional.only(end: 8.0),
                            child: InputChip(
                              label: Text(
                                '${L10n.of(context, 'cat_filter_label')}${category.toUpperCase()} ($count)',
                                style: TextStyle(
                                  color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              deleteIcon: Icon(
                                Icons.close_rounded,
                                size: 14,
                                color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                              ),
                              onDeleted: () {
                                if (context.read<SettingsProvider>().vibration) {
                                  HapticFeedback.lightImpact();
                                }
                                context.read<DownloadProvider>().toggleCategoryFilter(category);
                              },
                              backgroundColor: (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen).withValues(alpha: 0.1),
                              side: BorderSide(
                                color: (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen).withValues(alpha: 0.35),
                                width: 0.8,
                              ),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            ),
                          );
                        },
                      ),
                    ),
                  Expanded(
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: filters.length,
                      itemBuilder: (context, index) {
                        final filter = filters[index];
                        final isSelected = state.activeFilter == filter;

                        final filterClr = switch (filter) {
                          'All' => isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                          'Downloading' => isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                          'Completed' => isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                          'Failed' => isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                          'Paused' => isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                          'Scheduled' => isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
                          'Torrents' => isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                          _ => isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                        };

                        return Padding(
                          padding: const EdgeInsetsDirectional.only(end: 8.0),
                          child: Container(
                            decoration: BoxDecoration(
                              color: isSelected ? filterClr.withValues(alpha: 0.12) : glassBg,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: isSelected ? filterClr.withValues(alpha: 0.5) : glassBorder,
                                width: 1.0,
                              ),
                            ),
                            child: Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(20),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () => context.read<DownloadProvider>().setStatusFilter(filter),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  child: Center(
                                    widthFactor: 1.0,
                                    heightFactor: 1.0,
                                    child: Text(
                                      (() {
                                        switch (filter) {
                                          case 'All':
                                            return L10n.of(context, 'filter_all').toUpperCase();
                                          case 'Downloading':
                                            return L10n.of(context, 'stats_downloading').toUpperCase();
                                          case 'Completed':
                                            return L10n.of(context, 'stats_completed_short').toUpperCase();
                                          case 'Failed':
                                            return L10n.of(context, 'stats_failed_short').toUpperCase();
                                          case 'Paused':
                                            return L10n.of(context, 'stats_paused_short').toUpperCase();
                                          case 'Scheduled':
                                            return L10n.of(context, 'add_download_schedule').toUpperCase();
                                          case 'Torrents':
                                            return L10n.of(context, 'filter_torrents').toUpperCase();
                                          default:
                                            return filter.toUpperCase();
                                        }
                                      })(),
                                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                        color: isSelected ? filterClr : secClr,
                                        fontSize: 10,
                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                        letterSpacing: 1.0,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

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
        Object.hashAll(categoryCounts.entries.map((e) => Object.hash(e.key, e.value))),
      );
}