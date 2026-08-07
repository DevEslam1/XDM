import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/widgets/download_card.dart';
import '../../settings/provider/settings_provider.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';

import '../../downloads/widgets/filter_chips_bar.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isRtl = L10n.isRtl(context);

    return Selector<SettingsProvider, ({bool isDarkMode, bool isAmoledMode})>(
      selector: (_, s) =>
          (isDarkMode: s.isDarkMode, isAmoledMode: s.isAmoledMode),
      builder: (context, settingsState, _) {
        final isDark = settingsState.isDarkMode;
        final isAmoled = settingsState.isAmoledMode;
        final textClr =
            isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
        final secClr =
            isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
        final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
        final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
        final downloadProvider = context.watch<DownloadProvider>();
        final accentClr = getActiveFilterColor(downloadProvider, isDark);

        return Selector<DownloadProvider, List<DownloadTask>>(
          selector: (_, provider) => provider.tasks.where((task) {
            final isSeeding = task.status == DownloadStatus.completed &&
                task.isTorrent &&
                task.seedingEnabled;
            return (task.status == DownloadStatus.completed ||
                    task.status == DownloadStatus.failed) &&
                !isSeeding;
          }).toList(),
          shouldRebuild: (prev, next) {
            if (prev.length != next.length) return true;
            for (int i = 0; i < prev.length; i++) {
              if (prev[i].id != next[i].id ||
                  prev[i].status != next[i].status) {
                return true;
              }
            }
            return false;
          },
          builder: (context, historyTasksFromProvider, _) {
            // Apply search query locally
            final historyTasks = historyTasksFromProvider.where((task) {
              if (_searchQuery.trim().isEmpty) return true;
              return task.fileName
                      .toLowerCase()
                      .contains(_searchQuery.toLowerCase()) ||
                  task.url.toLowerCase().contains(_searchQuery.toLowerCase());
            }).toList();

            return GeometricGridBackground(
              child: Scaffold(
                backgroundColor: Colors.transparent,
                appBar: AppBar(
                  backgroundColor: isDark
                      ? (isAmoled
                          ? AppTheme.amoledBackground
                          : Colors.transparent)
                      : Colors.transparent,
                  flexibleSpace: isAmoled
                      ? null
                      : ClipRect(
                          child: DmxBackdropFilter(
                            sigmaX: 12,
                            sigmaY: 12,
                            child: Container(
                              color: (isDark
                                      ? AppTheme.surface
                                      : AppTheme.lightSurface)
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                  title: Text(
                    'XDM',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: textClr,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                          fontSize: 16,
                        ),
                  ),
                  automaticallyImplyLeading: false,
                  actions: [
                    if (historyTasks.isNotEmpty)
                      IconButton(
                        icon: Icon(
                          Icons.delete_sweep_outlined,
                          color: redClr,
                        ),
                        tooltip: L10n.of(context, 'clear_history_logs'),
                        onPressed: () => _showClearHistoryConfirmation(
                          context,
                          context.read<DownloadProvider>(),
                          // Always pass the full (unfiltered) history list so
                          // "Clear All" clears everything regardless of search.
                          historyTasksFromProvider,
                          context.read<SettingsProvider>(),
                        ),
                      ),
                    const SizedBox(width: 8),
                  ],
                ),
                body: Directionality(
                  textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                  child: SafeArea(
                    child: Column(
                      children: [
                        // Search Bar
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16.0,
                            vertical: 8.0,
                          ),
                          child: Theme(
                            data: Theme.of(context).copyWith(
                              primaryColor: accentClr,
                              colorScheme:
                                  Theme.of(context).colorScheme.copyWith(
                                        primary: accentClr,
                                      ),
                              textSelectionTheme: TextSelectionThemeData(
                                cursorColor: accentClr,
                                selectionColor:
                                    accentClr.withValues(alpha: 0.3),
                                selectionHandleColor: accentClr,
                              ),
                            ),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              height: 44,
                              decoration: BoxDecoration(
                                color: isDark
                                    ? AppTheme.surface
                                    : AppTheme.lightSurface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _searchFocusNode.hasFocus
                                      ? accentClr
                                      : accentClr.withValues(alpha: 0.35),
                                  width: _searchFocusNode.hasFocus ? 1.8 : 1.0,
                                ),
                                boxShadow: _searchFocusNode.hasFocus
                                    ? [
                                        BoxShadow(
                                          color:
                                              accentClr.withValues(alpha: 0.3),
                                          blurRadius: 10,
                                          spreadRadius: 1,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: TextField(
                                focusNode: _searchFocusNode,
                                controller: _searchController,
                                cursorColor: accentClr,
                                style: TextStyle(
                                  color: textClr,
                                  fontSize: 13,
                                  fontFamily: 'Inter',
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText:
                                      L10n.of(context, 'search_settings_hint'),
                                  hintStyle: TextStyle(
                                    color: mutedClr,
                                    fontSize: 12,
                                  ),
                                  prefixIcon: Icon(
                                    Icons.search_rounded,
                                    color: accentClr,
                                    size: 18,
                                  ),
                                  suffixIcon: _searchQuery.isNotEmpty
                                      ? IconButton(
                                          icon: Icon(Icons.clear_rounded,
                                              size: 16, color: accentClr),
                                          onPressed: () {
                                            _searchController.clear();
                                            setState(() {
                                              _searchQuery = '';
                                            });
                                          },
                                        )
                                      : null,
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                                onChanged: (value) {
                                  if (_debounceTimer?.isActive ?? false) {
                                    _debounceTimer!.cancel();
                                  }
                                  _debounceTimer = Timer(
                                      const Duration(milliseconds: 300), () {
                                    if (mounted) {
                                      setState(() {
                                        _searchQuery = value;
                                      });
                                    }
                                  });
                                },
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),

                        // History count header
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                L10n.of(context, 'resolved_transmissions'),
                                style: Theme.of(context)
                                    .textTheme
                                    .labelMedium
                                    ?.copyWith(
                                      color: secClr,
                                      fontSize: 9,
                                      letterSpacing: 1.0,
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                              Text(
                                '${historyTasks.length} ${L10n.of(context, 'records')}',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: mutedClr,
                                      fontSize: 9,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),

                        // History Tasks List
                        Expanded(
                          child: historyTasks.isEmpty
                              ? _buildEmptyState(
                                  context,
                                  isDark,
                                  isRtl,
                                  hasRecords:
                                      historyTasksFromProvider.isNotEmpty,
                                  hasQuery: _searchQuery.trim().isNotEmpty,
                                  onClearSearch: () {
                                    if (mounted) {
                                      setState(() => _searchQuery = '');
                                    }
                                  },
                                )
                              : Builder(
                                  builder: (context) {
                                    final isWide =
                                        MediaQuery.sizeOf(context).width >= 600;
                                    if (isWide) {
                                      return GridView.builder(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16.0, vertical: 4.0),
                                        physics: const BouncingScrollPhysics(),
                                        gridDelegate:
                                            const SliverGridDelegateWithMaxCrossAxisExtent(
                                          maxCrossAxisExtent: 540,
                                          mainAxisExtent: 155,
                                          crossAxisSpacing: 14,
                                          mainAxisSpacing: 12,
                                        ),
                                        itemCount: historyTasks.length,
                                        itemBuilder: (context, index) {
                                          return DownloadCard(
                                            task: historyTasks[index],
                                            compact: true,
                                          );
                                        },
                                      );
                                    }
                                    return ListView.builder(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16.0),
                                      physics: const BouncingScrollPhysics(),
                                      itemCount: historyTasks.length,
                                      itemBuilder: (context, index) {
                                        return DownloadCard(
                                          task: historyTasks[index],
                                          compact: true,
                                        );
                                      },
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState(
    BuildContext context,
    bool isDark,
    bool isRtl, {
    required bool hasRecords,
    required bool hasQuery,
    required VoidCallback onClearSearch,
  }) {
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final glassBg = isDark ? AppTheme.glassBg : AppTheme.lightGlassBg;
    final glassBorder =
        isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;

    final isNoMatch = hasQuery && hasRecords;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: glassBg,
              border: Border.all(color: glassBorder, width: 0.8),
              boxShadow: isDark
                  ? [
                      BoxShadow(
                        color: violetClr.withValues(alpha: 0.05),
                        blurRadius: 20.0,
                        spreadRadius: 0,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              isNoMatch
                  ? Icons.search_off_outlined
                  : Icons.history_toggle_off_outlined,
              size: 40,
              color: mutedClr,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            isNoMatch
                ? L10n.of(context, 'no_matching_records')
                : L10n.of(context, 'no_completed_signals'),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: secClr,
                  letterSpacing: 1.0,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            isNoMatch
                ? L10n.of(context, 'try_different_search')
                : L10n.of(context, 'finished_logs_cataloged'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: mutedClr,
                  fontSize: 11,
                ),
          ),
          if (isNoMatch) ...[
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: onClearSearch,
              icon: const Icon(Icons.clear, size: 16),
              label: Text(L10n.of(context, 'clear_search')),
            ),
          ],
        ],
      ),
    );
  }

  void _showClearHistoryConfirmation(
    BuildContext context,
    DownloadProvider provider,
    List<DownloadTask> tasksToClear,
    SettingsProvider settings,
  ) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final surfaceClr = isDark ? AppTheme.surface : AppTheme.lightSurface;
    final glassBorder =
        isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Directionality(
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: AlertDialog(
            backgroundColor: surfaceClr.withValues(alpha: 0.92),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: glassBorder, width: 0.8),
            ),
            title: Text(
              L10n.of(context, 'clear_history_logs'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: redClr,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
            ),
            content: Text(
              '${L10n.of(context, 'clear_history_logs')} (${tasksToClear.length})',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: secClr),
            ),
            actions: [
              TextButton(
                style: TextButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  L10n.of(context, 'cancel_btn'),
                  style: TextStyle(color: secClr),
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  L10n.of(context, 'clear_all'),
                  style: TextStyle(
                    color: redClr,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: () async {
                  await provider.clearHistoryTasks(
                      tasksToClear.map((t) => t.id).toList());
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
