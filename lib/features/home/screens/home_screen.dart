import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/responsive.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/widgets/download_card.dart';
import '../../downloads/widgets/download_stats_panel.dart';
import '../../downloads/widgets/filter_chips_bar.dart';
import '../../settings/provider/settings_provider.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../add_download/widgets/add_download_dialog.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../shared/widgets/neon_glow_button.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with HapticHelper, TickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  bool _showAnalytics = false;
  int _selectedTab = 0;
  int selectedSegment = 0;

  @override
  void initState() {
    super.initState();
  }

  bool _isActiveTask(DownloadTask t) {
    final isSeeding =
        t.status == DownloadStatus.completed && t.isTorrent && t.seedingEnabled;
    return (t.status != DownloadStatus.completed &&
            t.status != DownloadStatus.failed) ||
        isSeeding;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _switchTab(int index) {
    if (_selectedTab == index) return;
    triggerHaptic(context.read<SettingsProvider>());
    setState(() {
      _selectedTab = index;
      selectedSegment = index;
    });
    final provider = context.read<DownloadProvider>();
    provider.setStatusFilter('All');
    provider.clearCategoryFilters();
  }

  @override
  Widget build(BuildContext context) {
    return Selector<SettingsProvider,
        ({bool isDarkMode, bool classicUi, String languageCode})>(
      selector: (_, s) => (
        isDarkMode: s.isDarkMode,
        classicUi: s.classicUi,
        languageCode: s.languageCode,
      ),
      builder: (context, settingsState, _) {
        final isDark = settingsState.isDarkMode;
        final classicUi = settingsState.classicUi;
        final textClr =
            isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
        final accentClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
        final isRtl = L10n.isRtl(context);

        return GeometricGridBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            extendBody: true,
            floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
            appBar: _buildAppBar(
              context,
              isDark: isDark,
              classicUi: classicUi,
              textClr: textClr,
              accentClr: accentClr,
              isRtl: isRtl,
            ),
            body: SafeArea(
              child: Center(
                child: SizedBox(
                  width: contentMaxWidth(context),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 12),
                      // FIX(14): iOS has no persistent background downloads —
                      // surface that clearly so users don't assume downloads
                      // continue while the app is backgrounded.
                      ..._buildIosBackgroundBanner(isDark, isRtl),
                      _buildAnimatedSegmentedControl(
                        context,
                        isDark: isDark,
                        isRtl: isRtl,
                      ),
                      const SizedBox(height: 12),
                      // Analytics Panel
                      AnimatedSize(
                        duration: const Duration(milliseconds: 350),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: _showAnalytics
                            ? Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16.0,
                                  vertical: 4.0,
                                ),
                                child: Selector<DownloadProvider,
                                    Map<String, double>>(
                                  selector: (_, provider) =>
                                      provider.categorySizes,
                                  shouldRebuild: (prev, next) {
                                    if (prev.length != next.length) {
                                      return true;
                                    }
                                    for (final key in prev.keys) {
                                      if (prev[key] != next[key]) {
                                        return true;
                                      }
                                    }
                                    return false;
                                  },
                                  builder: (context, categorySizes, _) =>
                                      RepaintBoundary(
                                    child: _RedesignedAnalyticsPanel(
                                      categorySizes: categorySizes,
                                      settings:
                                          context.read<SettingsProvider>(),
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      // Stats Panel (Active tab only)
                      AnimatedSize(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOutCubic,
                        child: _selectedTab == 0
                            ? const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 16.0,
                                  vertical: 8.0,
                                ),
                                child: DownloadStatsPanel(),
                              )
                            : const SizedBox.shrink(),
                      ),
                      // Filter Chips
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: FilterChipsBar(isHistory: _selectedTab == 1),
                      ),
                      const SizedBox(height: 12),
                      // Section Header + Controls
                      _buildSectionHeader(
                        context,
                        isDark: isDark,
                        isRtl: isRtl,
                      ),
                      const SizedBox(height: 8),
                      // Task List
                      Expanded(
                        child: _DownloadTaskList(
                          selectedTab: _selectedTab,
                          isDark: isDark,
                          isRtl: isRtl,
                          settings: context.read<SettingsProvider>(),
                          onClearSearch: () {
                            _searchController.clear();
                            context.read<DownloadProvider>().setSearchQuery('');
                            setState(() {});
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            floatingActionButton: _buildFAB(context, isDark, classicUi),
          ),
        );
      },
    );
  }

  /// FIX(14): persistent iOS-only banner. BackgroundService only keeps Dart
  /// alive on Android; on iOS the app is suspended and downloads pause.
  List<Widget> _buildIosBackgroundBanner(bool isDark, bool isRtl) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return const [];
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: accent.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isRtl
                      ? 'تتوقف التنزيلات عند وضع التطبيق في الخلفية.'
                      : 'Downloads pause when the app is in the background.',
                  style: TextStyle(fontSize: 12.5, color: textClr),
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context, {
    required bool isDark,
    required bool classicUi,
    required Color textClr,
    required Color accentClr,
    required bool isRtl,
  }) {
    return AppBar(
      backgroundColor: classicUi
          ? (isDark ? AppTheme.surface : AppTheme.lightSurface)
          : Colors.transparent,
      elevation: 0,
      shape: classicUi
          ? Border(
              bottom: BorderSide(
                color: isDark ? AppTheme.border : AppTheme.lightBorder,
                width: 1.0,
              ),
            )
          : null,
      titleSpacing: 16,
      title: _isSearching
          ? _buildSearchField(context, textClr, isDark)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'XDM',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: textClr,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.0,
                        fontSize: 18,
                      ),
                ),
              ],
            ),
      actions: [
        if (!_isSearching)
          _AppBarIconButton(
            icon: _showAnalytics
                ? Icons.pie_chart_rounded
                : Icons.pie_chart_outline_rounded,
            color: _showAnalytics ? accentClr : textClr,
            tooltip: L10n.of(context, 'storage_analytics'),
            onPressed: () {
              triggerHaptic(context.read<SettingsProvider>());
              setState(() => _showAnalytics = !_showAnalytics);
            },
          ),
        _AppBarIconButton(
          icon: _isSearching ? Icons.close_rounded : Icons.search_rounded,
          color: textClr,
          onPressed: () {
            triggerHaptic(context.read<SettingsProvider>());
            setState(() {
              if (_isSearching) {
                _isSearching = false;
                _searchController.clear();
                context.read<DownloadProvider>().setSearchQuery('');
              } else {
                _isSearching = true;
              }
            });
          },
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildSearchField(BuildContext context, Color textClr, bool isDark) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.surface : AppTheme.lightBgSunken,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? AppTheme.border : AppTheme.lightBorder,
          width: 0.8,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            size: 18,
            color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              autofocus: true,
              style: TextStyle(color: textClr, fontSize: 14),
              decoration: InputDecoration(
                hintText: L10n.of(context, 'search_placeholder'),
                hintStyle: TextStyle(
                  color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                  fontSize: 13,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                isDense: true,
              ),
              onChanged: (val) {
                setState(() {});
                context.read<DownloadProvider>().setSearchQuery(val);
              },
            ),
          ),
          if (_searchController.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchController.clear();
                context.read<DownloadProvider>().setSearchQuery('');
                setState(() {});
              },
              child: Icon(
                Icons.clear_rounded,
                size: 16,
                color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAnimatedSegmentedControl(
    BuildContext context, {
    required bool isDark,
    required bool isRtl,
  }) {
    return Selector<DownloadProvider, List<DownloadTask>>(
      selector: (_, p) => p.filteredTasks,
      builder: (context, allTasks, _) {
        final activeCount = allTasks.where(_isActiveTask).length;
        final historyCount = allTasks.where((DownloadTask t) {
          final isSeeding = t.status == DownloadStatus.completed &&
              t.isTorrent &&
              t.seedingEnabled;
          return (t.status == DownloadStatus.completed ||
                  t.status == DownloadStatus.failed) &&
              !isSeeding;
        }).length;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                _buildSegment(
                  context,
                  0,
                  L10n.of(context, 'active_tab'),
                  activeCount,
                  isDark,
                ),
                _buildSegment(
                  context,
                  1,
                  L10n.of(context, 'completed_tab'),
                  historyCount,
                  isDark,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSegment(
    BuildContext context,
    int index,
    String label,
    int count,
    bool isDark,
  ) {
    final selected = selectedSegment == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => _switchTab(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutQuart,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? (index == 1
                    ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
                    : Theme.of(context).colorScheme.primary)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? Colors.white
                      : (isDark ? Colors.white70 : Colors.black87),
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? Colors.white.withValues(alpha: 0.25)
                        : (isDark
                            ? Colors.white.withValues(alpha: 0.10)
                            : Colors.black.withValues(alpha: 0.08)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    style: TextStyle(
                      color: selected
                          ? Colors.white
                          : (isDark ? Colors.white70 : Colors.black54),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context, {
    required bool isDark,
    required bool isRtl,
  }) {
    final provider = context.read<DownloadProvider>();
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Row(
        children: [
          // Section title
          Expanded(
            child: Selector<DownloadProvider, int>(
              selector: (_, p) {
                final tasks = p.filteredTasks;
                var count = 0;
                for (final t in tasks) {
                  final isActive = _isActiveTask(t);
                  if (_selectedTab == 0 ? isActive : !isActive) count++;
                }
                return count;
              },
              builder: (context, count, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        _selectedTab == 0
                            ? L10n.of(context, 'active_transmissions_header')
                            : L10n.of(
                                context, 'completed_transmissions_header'),
                        style: TextStyle(
                          color: textClr,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.10)
                              : Colors.black.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '$count',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: mutedClr,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$count ${L10n.of(context, 'items_count')}',
                    style: TextStyle(
                      color: mutedClr,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Sort button
          Selector<DownloadProvider, ({SortOption option, bool ascending})>(
            selector: (_, p) =>
                (option: p.sortOption, ascending: p.sortAscending),
            builder: (context, sortState, _) {
              return PopupMenuButton<SortOption>(
                tooltip: L10n.of(context, 'sort_tooltip'),
                color: isDark ? AppTheme.surface : AppTheme.lightSurface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: isDark
                        ? AppTheme.glassBorder
                        : AppTheme.lightGlassBorder,
                    width: 0.6,
                  ),
                ),
                offset: const Offset(0, 40),
                onSelected: (option) {
                  if (provider.sortOption == option) {
                    provider.toggleSortDirection();
                  } else {
                    provider.setSortOption(option);
                  }
                },
                itemBuilder: (context) => [
                  _sortMenuItem(
                    SortOption.dateAdded,
                    L10n.of(context, 'sort_date'),
                    sortState,
                    isDark,
                  ),
                  _sortMenuItem(
                    SortOption.fileSize,
                    L10n.of(context, 'details_size'),
                    sortState,
                    isDark,
                  ),
                  _sortMenuItem(
                    SortOption.fileName,
                    L10n.of(context, 'details_filename'),
                    sortState,
                    isDark,
                  ),
                  _sortMenuItem(
                    SortOption.status,
                    L10n.of(context, 'sort_status'),
                    sortState,
                    isDark,
                  ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: (isDark ? AppTheme.glassBg : AppTheme.lightGlassBg),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isDark
                          ? AppTheme.glassBorder
                          : AppTheme.lightGlassBorder,
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        sortState.ascending
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        color: secClr,
                        size: 13,
                      ),
                      const SizedBox(width: 5),
                      Icon(Icons.sort_rounded, color: secClr, size: 14),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          // Clear history button (Completed tab only)
          Selector<DownloadProvider, int>(
            selector: (_, p) => p.filteredTasks.length,
            builder: (context, length, _) {
              if (_selectedTab != 1 || length == 0) {
                return const SizedBox.shrink();
              }
              return GestureDetector(
                onTap: () =>
                    _showClearHistoryDialog(context, provider, isDark, isRtl),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
                          .withValues(alpha: 0.25),
                      width: 0.8,
                    ),
                  ),
                  child: Icon(
                    Icons.delete_sweep_outlined,
                    color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                    size: 16,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  PopupMenuItem<SortOption> _sortMenuItem(
    SortOption option,
    String label,
    ({SortOption option, bool ascending}) sortState,
    bool isDark,
  ) {
    final isSelected = sortState.option == option;
    final activeColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final textColor = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    return PopupMenuItem<SortOption>(
      value: option,
      height: 44,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: isSelected ? activeColor : textColor,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              fontSize: 12,
            ),
          ),
          if (isSelected)
            Icon(
              sortState.ascending
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded,
              color: activeColor,
              size: 14,
            ),
        ],
      ),
    );
  }

  Widget _buildFAB(BuildContext context, bool isDark, bool classicUi) {
    final accentClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final screenType = getScreenType(context);
    final downloadProvider = context.watch<DownloadProvider>();
    final isNavbarVisible = downloadProvider.isNavbarVisible;
    final safeAreaBottom = MediaQuery.paddingOf(context).bottom;

    final double bottomPadding;
    switch (screenType) {
      case ScreenType.phone:
        bottomPadding =
            isNavbarVisible ? (20.0 + safeAreaBottom) : (16.0 + safeAreaBottom);
        break;
      case ScreenType.tablet:
        bottomPadding =
            isNavbarVisible ? (96.0 + safeAreaBottom) : (16.0 + safeAreaBottom);
        break;
      case ScreenType.desktop:
        bottomPadding = 0.0;
        break;
    }

    return AnimatedPadding(
      padding: EdgeInsets.only(bottom: bottomPadding),
      duration: AppTheme.motionBase,
      curve: AppTheme.motionCurve,
      child: Container(
        decoration: classicUi
            ? null
            : BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: accentClr.withValues(alpha: 0.35),
                    blurRadius: 16.0,
                    spreadRadius: 0,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
        child: Semantics(
          button: true,
          label: 'Add new download',
          hint: 'Double tap to create a new download',
          child: FloatingActionButton(
            heroTag: null,
            backgroundColor: accentClr,
            foregroundColor: Colors.white,
            elevation: classicUi ? 4 : 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(
                color: Colors.white.withValues(alpha: 0.2),
                width: 0.8,
              ),
            ),
            onPressed: () {
              triggerHaptic(context.read<SettingsProvider>());
              showDialog(
                context: context,
                builder: (_) => const AddDownloadDialog(),
              );
            },
            child: const Icon(Icons.add_rounded, size: 22),
          ),
        ),
      ),
    );
  }

  void _showClearHistoryDialog(
    BuildContext context,
    DownloadProvider provider,
    bool isDark,
    bool isRtl,
  ) {
    final surfaceClr = isDark ? AppTheme.surface : AppTheme.lightSurface;
    final glassBorder =
        isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    showDialog(
      context: context,
      builder: (ctx) {
        final tasksToClear = provider.filteredTasks.where((task) {
          final isSeeding = task.status == DownloadStatus.completed &&
              task.isTorrent &&
              task.seedingEnabled;
          return (task.status == DownloadStatus.completed ||
                  task.status == DownloadStatus.failed) &&
              !isSeeding;
        }).toList();

        return Directionality(
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: AlertDialog(
            backgroundColor: surfaceClr.withValues(alpha: 0.95),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: glassBorder, width: 0.8),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: redClr.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.delete_sweep_rounded,
                    color: redClr,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    L10n.of(context, 'clear_history'),
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          color: redClr,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
              ],
            ),
            content: Text(
              isRtl
                  ? 'هل أنت متأكد من حذف جميع ${tasksToClear.length} سجل مكتمل؟'
                  : 'Delete all ${tasksToClear.length} completed records? This cannot be undone.',
              style: Theme.of(
                ctx,
              ).textTheme.bodyMedium?.copyWith(color: secClr, height: 1.4),
            ),
            actions: [
              TextButton(
                style: TextButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  L10n.of(ctx, 'cancel_btn'),
                  style: TextStyle(color: secClr),
                ),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: redClr.withValues(alpha: 0.1),
                  foregroundColor: redClr,
                  side: BorderSide(color: redClr.withValues(alpha: 0.4)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  L10n.of(context, 'clear_all'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                onPressed: () async {
                  for (final task in tasksToClear) {
                    await provider.deleteTask(task.id);
                  }
                  if (ctx.mounted) Navigator.of(ctx).pop();
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// App Bar Icon Button
// ─────────────────────────────────────────────────────────────────────────────
class _AppBarIconButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String? tooltip;
  final VoidCallback onPressed;

  const _AppBarIconButton({
    required this.icon,
    required this.color,
    this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: color, size: 20),
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        highlightColor: color.withValues(alpha: 0.12),
        hoverColor: color.withValues(alpha: 0.08),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Redesigned Analytics Panel
// ─────────────────────────────────────────────────────────────────────────────
class _RedesignedAnalyticsPanel extends StatelessWidget {
  final Map<String, double> categorySizes;
  final SettingsProvider settings;

  const _RedesignedAnalyticsPanel({
    required this.categorySizes,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = settings.isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final isRtl = L10n.isRtl(context);

    final sizes = categorySizes;
    final totalSizeMb = sizes.values.fold(0.0, (sum, val) => sum + val);
    final hasNoData = totalSizeMb == 0.0;

    final totalSizeText = totalSizeMb >= 1024
        ? '${(totalSizeMb / 1024).toStringAsFixed(2)} GB'
        : '${totalSizeMb.toStringAsFixed(1)} MB';

    final categoryCards = [
      {
        'name': 'Video',
        'color': isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        'icon': Icons.movie_rounded,
      },
      {
        'name': 'Audio',
        'color': isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
        'icon': Icons.audiotrack_rounded,
      },
      {
        'name': 'Document',
        'color': isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
        'icon': Icons.description_rounded,
      },
      {
        'name': 'Archive',
        'color': isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
        'icon': Icons.folder_zip_rounded,
      },
      {
        'name': 'APK',
        'color': const Color(0xFFF15BB5),
        'icon': Icons.android_rounded,
      },
      {
        'name': 'Other',
        'color': isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
        'icon': Icons.insert_drive_file_rounded,
      },
    ];

    final activeCategoryNames = hasNoData
        ? <String>[]
        : categoryCards
            .where((card) => (sizes[card['name']] ?? 0.0) > 0)
            .map<String>((card) => card['name'] as String)
            .toList();

    final sections = hasNoData
        ? [
            PieChartSectionData(
              color: (isDark ? AppTheme.border : AppTheme.lightBorder)
                  .withValues(alpha: 0.4),
              value: 1.0,
              radius: 14,
              title: '',
            ),
          ]
        : activeCategoryNames.map((name) {
            final card = categoryCards.firstWhere((c) => c['name'] == name);
            final sizeMb = sizes[name] ?? 0.0;
            final percentage =
                totalSizeMb > 0 ? (sizeMb / totalSizeMb) * 100 : 0.0;
            return PieChartSectionData(
              color: card['color'] as Color,
              value: sizeMb,
              radius: 14,
              title:
                  percentage >= 12 ? '${percentage.toStringAsFixed(0)}%' : '',
              titleStyle: const TextStyle(
                color: Colors.white,
                fontSize: 8,
                fontWeight: FontWeight.bold,
              ),
            );
          }).toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: settings.classicUi
          ? BoxDecoration(
              color: isDark ? AppTheme.surface : AppTheme.lightSurface,
              border: Border.all(
                color: isDark ? AppTheme.border : AppTheme.lightBorder,
                width: 1.0,
              ),
              borderRadius: BorderRadius.circular(20),
            )
          : AppTheme.glassDecoration(borderRadius: 20, isDark: isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(
                Icons.storage_rounded,
                size: 14,
                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
              ),
              const SizedBox(width: 8),
              Text(
                L10n.of(context, 'storage_analytics'),
                style: TextStyle(
                  color: mutedClr,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              Text(
                totalSizeText,
                style: TextStyle(
                  color: textClr,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'Space Grotesk',
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Chart + Legend
          Row(
            children: [
              // Donut chart
              SizedBox(
                width: 120,
                height: 120,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.08),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                    PieChart(
                      PieChartData(
                        pieTouchData: PieTouchData(
                          touchCallback:
                              (FlTouchEvent event, pieTouchResponse) {
                            if (!event.isInterestedForInteractions ||
                                pieTouchResponse?.touchedSection == null) {
                              return;
                            }
                            final touchedIndex = pieTouchResponse!
                                .touchedSection!.touchedSectionIndex;
                            if (touchedIndex >= 0 &&
                                touchedIndex < activeCategoryNames.length) {
                              context
                                  .read<DownloadProvider>()
                                  .toggleCategoryFilter(
                                    activeCategoryNames[touchedIndex],
                                  );
                            }
                          },
                        ),
                        sections: sections,
                        centerSpaceRadius: 35,
                        sectionsSpace: 2.0,
                      ),
                    ),
                    // Center label
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.donut_large_rounded,
                          size: 18,
                          color: mutedClr.withValues(alpha: 0.5),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Legend items
              Expanded(
                child: hasNoData
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            L10n.of(context, 'no_data_available'),
                            style: TextStyle(
                              color: mutedClr,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      )
                    : Column(
                        children: categoryCards
                            .where((card) => (sizes[card['name']] ?? 0.0) > 0)
                            .take(4)
                            .map((card) {
                          final name = card['name'] as String;
                          final sizeMb = sizes[name] ?? 0.0;
                          final pct = totalSizeMb > 0
                              ? (sizeMb / totalSizeMb) * 100
                              : 0.0;
                          final sizeText = sizeMb >= 1024
                              ? '${(sizeMb / 1024).toStringAsFixed(1)}G'
                              : '${sizeMb.toStringAsFixed(0)}M';
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 3,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: card['color'] as Color,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  card['icon'] as IconData,
                                  size: 11,
                                  color: (card['color'] as Color)
                                      .withValues(alpha: 0.7),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    isRtl ? _translateCat(name) : name,
                                    style: TextStyle(
                                      color: textClr,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  '${pct.toStringAsFixed(0)}%',
                                  style: TextStyle(
                                    color: card['color'] as Color,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  sizeText,
                                  style: TextStyle(
                                    color: mutedClr,
                                    fontSize: 9,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _translateCat(String name) {
    switch (name) {
      case 'Video':
        return 'الفيديو';
      case 'Audio':
        return 'الصوت';
      case 'Document':
        return 'المستندات';
      case 'Archive':
        return 'الأرشيف';
      case 'APK':
        return 'التطبيقات';
      default:
        return 'أخرى';
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Render item descriptor – keeps widget construction lazy inside itemBuilder
// ─────────────────────────────────────────────────────────────────────────────
class _RenderItem {
  final bool isPlaylist;
  final String? playlistId;
  final String? title;
  final List<DownloadTask>? items;
  final DownloadTask? task;

  const _RenderItem._({
    required this.isPlaylist,
    this.playlistId,
    this.title,
    this.items,
    this.task,
  });

  const _RenderItem.playlist({
    required String playlistId,
    required String title,
    required List<DownloadTask> items,
  }) : this._(
          isPlaylist: true,
          playlistId: playlistId,
          title: title,
          items: items,
        );

  const _RenderItem.single({required DownloadTask task})
      : this._(isPlaylist: false, task: task);
}

// ─────────────────────────────────────────────────────────────────────────────
// Download Task List
// ─────────────────────────────────────────────────────────────────────────────
class _DownloadTaskList extends StatelessWidget {
  final int selectedTab;
  final bool isDark;
  final bool isRtl;
  final SettingsProvider settings;
  final VoidCallback? onClearSearch;

  const _DownloadTaskList({
    required this.selectedTab,
    required this.isDark,
    required this.isRtl,
    required this.settings,
    this.onClearSearch,
  });

  Widget _buildLoadingSkeleton(bool isDark, BuildContext context) {
    final cardBg = isDark ? AppTheme.surface : AppTheme.lightSurface;
    final baseShimmer = isDark ? Colors.white10 : Colors.black12;
    return ListView.separated(
      padding: EdgeInsets.symmetric(horizontal: screenPadding(context).left),
      itemCount: 3,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, __) => Container(
        height: 110,
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isDark ? AppTheme.border : AppTheme.lightBorder,
            width: 0.8,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: baseShimmer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 140,
                          height: 12,
                          decoration: BoxDecoration(
                            color: baseShimmer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: 80,
                          height: 10,
                          decoration: BoxDecoration(
                            color: baseShimmer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Container(
                height: 6,
                decoration: BoxDecoration(
                  color: baseShimmer,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (context.watch<DownloadProvider>().isLoadingTasks) {
      return _buildLoadingSkeleton(isDark, context);
    }

    return Selector<DownloadProvider, List<DownloadTask>>(
      shouldRebuild: (prev, next) {
        if (prev.length != next.length) return true;
        for (var i = 0; i < prev.length; i++) {
          final oldTask = prev[i];
          final newTask = next[i];
          if (oldTask.id != newTask.id ||
              oldTask.status != newTask.status ||
              oldTask.downloadedBytes != newTask.downloadedBytes ||
              oldTask.fileSize != newTask.fileSize ||
              oldTask.threadCount != newTask.threadCount ||
              !listEquals(oldTask.chunks, newTask.chunks) ||
              (oldTask.speed - newTask.speed).abs() > 50 ||
              oldTask.eta != newTask.eta) {
            return true;
          }
        }
        return false;
      },
      selector: (_, provider) => provider.filteredTasks,
      builder: (context, fullList, _) {
        final displayTasks = fullList.where((task) {
          final isSeeding = task.status == DownloadStatus.completed &&
              task.isTorrent &&
              task.seedingEnabled;
          if (selectedTab == 0) {
            return (task.status != DownloadStatus.completed &&
                    task.status != DownloadStatus.failed) ||
                isSeeding;
          } else {
            return (task.status == DownloadStatus.completed ||
                    task.status == DownloadStatus.failed) &&
                !isSeeding;
          }
        }).toList();

        final groups = <String, List<DownloadTask>>{};
        final singles = <DownloadTask>[];
        for (final t in displayTasks) {
          if (t.isPlaylistItem) {
            groups.putIfAbsent(t.playlistId!, () => []).add(t);
          } else {
            singles.add(t);
          }
        }

        // Build a mixed list preserving order: playlists first-seen, then singles
        final renderItems = <_RenderItem>[];
        final seenPlaylists = <String>{};
        for (final t in displayTasks) {
          if (t.isPlaylistItem) {
            if (seenPlaylists.contains(t.playlistId)) continue;
            seenPlaylists.add(t.playlistId!);
            renderItems.add(
              _RenderItem.playlist(
                playlistId: t.playlistId!,
                title: t.playlistTitle ?? 'Playlist',
                items: groups[t.playlistId!]!,
              ),
            );
          } else {
            renderItems.add(_RenderItem.single(task: t));
          }
        }

        if (displayTasks.isEmpty) {
          return _EmptyState(
            selectedTab: selectedTab,
            isDark: isDark,
            isRtl: isRtl,
            settings: settings,
            onClearSearch: onClearSearch,
          );
        }

        return RefreshIndicator(
          color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          strokeWidth: 2.5,
          onRefresh: () async {
            await context.read<DownloadProvider>().load(
                  pauseOrphanDownloads: false,
                );
            if (context.mounted) {
              ThemedSnackbar.show(
                context,
                message: isRtl
                    ? 'تم إعادة تحميل السجلات'
                    : 'Transmission logs reloaded',
                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                icon: Icons.sync_rounded,
                isDarkMode: isDark,
              );
            }
          },
          child: ListView.separated(
            padding: EdgeInsets.symmetric(
              horizontal: screenPadding(context).left,
            ),
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            itemCount: renderItems.length,
            separatorBuilder: (context, index) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final item = renderItems[index];
              final Widget card;
              if (item.isPlaylist) {
                card = PlaylistGroupCard(
                  key: ValueKey('playlist_${item.playlistId}'),
                  playlistId: item.playlistId!,
                  title: item.title!,
                  items: item.items!,
                );
              } else {
                card = DownloadCard(
                  key: ValueKey(item.task!.id),
                  task: item.task!,
                  compact: true,
                );
              }
              return RepaintBoundary(child: card);
            },
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty State
// ─────────────────────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  final int selectedTab;
  final bool isDark;
  final bool isRtl;
  final SettingsProvider settings;
  final VoidCallback? onClearSearch;

  const _EmptyState({
    required this.selectedTab,
    required this.isDark,
    required this.isRtl,
    required this.settings,
    this.onClearSearch,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DownloadProvider>();
    final query = provider.searchQuery;
    final accentClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    if (query.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accentClr.withValues(alpha: 0.06),
                  border: Border.all(color: accentClr.withValues(alpha: 0.15)),
                ),
                child: Icon(
                  Icons.search_off_rounded,
                  size: 36,
                  color: accentClr.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '${L10n.of(context, 'no_results_for')} "$query"',
                style: TextStyle(
                  color:
                      isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () {
                  onClearSearch?.call();
                  provider.setSearchQuery('');
                },
                icon: const Icon(Icons.clear_rounded, size: 16),
                label: Text(L10n.of(context, 'clear_search')),
                style: TextButton.styleFrom(foregroundColor: accentClr),
              ),
            ],
          ),
        ),
      );
    }

    final icon = selectedTab == 1
        ? Icons.inventory_2_outlined
        : Icons.cloud_download_outlined;
    final title = selectedTab == 1
        ? L10n.of(context, 'history_empty')
        : L10n.of(context, 'empty_transmissions');
    final subtitle = selectedTab == 1
        ? (isRtl
            ? 'تظهر جميع التنزيلات المكتملة والفاشلة هنا.'
            : 'Finished and failed downloads will be cataloged here.')
        : (isRtl
            ? 'أدخل رابطاً لبدء التنزيل.'
            : 'Insert a URL to start downloading.');

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutQuart,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - value)),
            child: child,
          ),
        );
      },
      child: Center(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: settings.classicUi
                      ? (isDark ? AppTheme.surface : AppTheme.lightSurface)
                      : (isDark ? AppTheme.glassBg : AppTheme.lightGlassBg),
                  border: Border.all(
                    color: settings.classicUi
                        ? (isDark ? AppTheme.border : AppTheme.lightBorder)
                        : (isDark
                            ? AppTheme.glassBorder
                            : AppTheme.lightGlassBorder),
                    width: 0.8,
                  ),
                  boxShadow: isDark && !settings.classicUi
                      ? [
                          BoxShadow(
                            color: accentClr.withValues(alpha: 0.04),
                            blurRadius: 24,
                            spreadRadius: 4,
                          ),
                        ]
                      : null,
                ),
                child: Icon(
                  icon,
                  size: 40,
                  color: (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted)
                      .withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: isDark
                          ? AppTheme.textSecondary
                          : AppTheme.lightTextSecondary,
                      letterSpacing: 0.5,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isDark
                            ? AppTheme.textMuted
                            : AppTheme.lightTextMuted,
                        fontSize: 11,
                        height: 1.4,
                      ),
                ),
              ),
              if (selectedTab == 0) ...[
                const SizedBox(height: 24),
                NeonGlowButton(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => const AddDownloadDialog(),
                    );
                  },
                  text: L10n.of(context, 'add_new_transmission'),
                  icon: Icons.add_rounded,
                  isFilled: true,
                  color: accentClr,
                  hasGlow: true,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
