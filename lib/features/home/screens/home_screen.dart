import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/intl_formatters.dart';
import '../../../core/utils/responsive.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/widgets/download_card.dart';
import '../../downloads/widgets/download_stats_panel.dart';
import '../../downloads/widgets/filter_chips_bar.dart';
import '../../downloads/widgets/batch_operations_sheet.dart';
import '../../settings/provider/settings_provider.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
// themed_snackbar removed - unused in this file
import '../../add_download/widgets/add_download_dialog.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../shared/widgets/skeleton_loader.dart';
import '../../../shared/mixins/pausable_loop_animation.dart';
import '../../../shared/design/dmx_design.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with HapticHelper, TickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _isSearching = false;
  bool _showAnalytics = false;
  int _selectedTab = 0;
  int selectedSegment = 0;
  late final AnimationController _reveal;

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(() {
      if (mounted) setState(() {});
    });
    _reveal = AnimationController(
      vsync: this,
      duration: AppTheme.motionReveal,
    )..forward();
  }

  Widget _stagger(double start, Widget child) {
    if (!modernAnimationsAllowed(context)) return child;
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: _reveal,
        curve: Interval(
          start,
          (start + 0.5).clamp(0.0, 1.0),
          curve: AppTheme.motionCurve,
        ),
      ),
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
            .animate(
          CurvedAnimation(
            parent: _reveal,
            curve: Interval(
              start,
              (start + 0.5).clamp(0.0, 1.0),
              curve: AppTheme.motionCurve,
            ),
          ),
        ),
        child: child,
      ),
    );
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
    _searchFocusNode.dispose();
    _reveal.dispose();
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
    provider.clearTaskSelection();
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
        final downloadProvider = context.watch<DownloadProvider>();
        final accentClr = getActiveFilterColor(downloadProvider, isDark);
        final isRtl = L10n.isRtl(context);

        final isInSelectionMode = downloadProvider.isSelectionMode;

        return GeometricGridBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            extendBody: true,
            floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
            appBar: isInSelectionMode
                ? _buildSelectionAppBar(context, isDark, textClr, accentClr)
                : _buildAppBar(
                    context,
                    isDark: isDark,
                    classicUi: classicUi,
                    textClr: textClr,
                    accentClr: accentClr,
                    isRtl: isRtl,
                  ),
            bottomNavigationBar: isInSelectionMode
                ? _buildBatchActionBar(context, isDark, textClr, accentClr)
                : null,
            body: SafeArea(
              child: Center(
                child: SizedBox(
                  width: contentMaxWidth(context),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 12),
                      // FIX(14): iOS has no persistent background downloads
                      ..._buildIosBackgroundBanner(isDark, isRtl),
                      _stagger(
                          0.0,
                          _buildAnimatedSegmentedControl(
                            context,
                            isDark: isDark,
                            isRtl: isRtl,
                          )),
                      const SizedBox(height: 12),
                      // Analytics Panel
                      _stagger(
                          0.08,
                          AnimatedSize(
                            duration: const Duration(milliseconds: 350),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.topCenter,
                            child: _showAnalytics
                                ? Padding(
                                    padding: EdgeInsets.only(
                                      left: screenPadding(context).left,
                                      right: screenPadding(context).left,
                                      top: 4.0,
                                      bottom: 20.0,
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
                          )),
                      // Stats Panel (Active tab only)
                      _stagger(
                          0.12,
                          AnimatedSize(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOutCubic,
                            child: _selectedTab == 0
                                ? Padding(
                                    padding: EdgeInsets.only(
                                      left: screenPadding(context).left,
                                      right: screenPadding(context).left,
                                      top: 4.0,
                                      bottom: 20.0,
                                    ),
                                    child: const DownloadStatsPanel(),
                                  )
                                : const SizedBox.shrink(),
                          )),

                      // Filter Chips
                      _stagger(
                          0.16,
                          Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: screenPadding(context).left),
                            child: FilterChipsBar(isHistory: _selectedTab == 1),
                          )),
                      const SizedBox(height: 20),
                      // Section Header + Controls
                      _stagger(
                          0.20,
                          _buildSectionHeader(
                            context,
                            isDark: isDark,
                            isRtl: isRtl,
                          )),
                      const SizedBox(height: 12),
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
            floatingActionButton: isInSelectionMode
                ? null
                : _buildFAB(context, isDark, classicUi),
          ),
        );
      },
    );
  }

  List<String> _visibleTaskIds(DownloadProvider provider) {
    return provider.filteredTasks
        .where((task) =>
            _selectedTab == 0 ? _isActiveTask(task) : !_isActiveTask(task))
        .map((task) => task.id)
        .toList();
  }

  PreferredSizeWidget _buildSelectionAppBar(
      BuildContext context, bool isDark, Color textClr, Color accentClr) {
    final provider = context.watch<DownloadProvider>();
    final settings = context.watch<SettingsProvider>();
    final isAmoled = settings.isAmoledMode;
    final count = provider.selectedTaskIds.length;

    return AppBar(
      backgroundColor: isDark
          ? (isAmoled ? AppTheme.amoledBackground : AppTheme.surface)
          : AppTheme.lightSurface,
      elevation: 0,
      leading: IconButton(
        icon: Icon(Icons.close_rounded, color: textClr),
        onPressed: () => provider.clearTaskSelection(),
      ),
      title: Text(
        L10n.of(context, 'selected_count', args: {'count': count}),
        style: TextStyle(color: textClr, fontWeight: FontWeight.w600),
      ),
      actions: [
        TextButton(
          onPressed: () => provider.selectAllTasks(
              visibleTaskIds: _visibleTaskIds(provider)),
          child: Text(L10n.of(context, 'select_all_btn'),
              style: TextStyle(color: accentClr)),
        ),
        TextButton(
          onPressed: () => provider.clearTaskSelection(),
          child: Text(L10n.of(context, 'deselect_btn'),
              style: TextStyle(color: textClr)),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildBatchActionBar(
      BuildContext context, bool isDark, Color textClr, Color accentClr) {
    final provider = context.watch<DownloadProvider>();
    final settings = context.watch<SettingsProvider>();
    final isAmoled = settings.isAmoledMode;
    final selectedIds = provider.selectedTaskIds;
    final safeAreaBottom = MediaQuery.paddingOf(context).bottom;

    return Container(
      padding: EdgeInsetsDirectional.only(
          bottom: safeAreaBottom + 8, top: 12, start: 16, end: 16),
      decoration: BoxDecoration(
        color: isDark
            ? (isAmoled ? AppTheme.amoledBackground : AppTheme.surface)
            : AppTheme.lightSurface,
        border: Border(
            top: BorderSide(
                color: isDark
                    ? (isAmoled ? AppTheme.amoledBorder : AppTheme.border)
                    : AppTheme.lightBorder,
                width: 0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceAround,
        runAlignment: WrapAlignment.center,
        runSpacing: 8,
        children: [
          _BatchActionButton(
            icon: Icons.pause_rounded,
            label: L10n.of(context, 'pause_btn'),
            color: textClr,
            onTap: () => BatchOperationsSheet.show(context,
                selectedTaskIds: selectedIds.toList(),
                initialAction: BatchAction.pause),
          ),
          _BatchActionButton(
            icon: Icons.play_arrow_rounded,
            label: L10n.of(context, 'resume_btn'),
            color: textClr,
            onTap: () => BatchOperationsSheet.show(context,
                selectedTaskIds: selectedIds.toList(),
                initialAction: BatchAction.resume),
          ),
          _BatchActionButton(
            icon: Icons.delete_rounded,
            label: L10n.of(context, 'delete_btn'),
            color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
            onTap: () => BatchOperationsSheet.show(context,
                selectedTaskIds: selectedIds.toList(),
                initialAction: BatchAction.delete),
          ),
          _BatchActionButton(
            icon: Icons.folder_rounded,
            label: L10n.of(context, 'change_category'),
            color: accentClr,
            onTap: () => BatchOperationsSheet.show(context,
                selectedTaskIds: selectedIds.toList(),
                initialAction: BatchAction.changeCategory),
          ),
        ],
      ),
    );
  }

  /// FIX(14): persistent iOS-only banner.
  List<Widget> _buildIosBackgroundBanner(bool isDark, bool isRtl) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return const [];
    final accent =
        getActiveFilterColor(context.watch<DownloadProvider>(), isDark);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    return [
      Padding(
        padding: EdgeInsets.symmetric(horizontal: screenPadding(context).left),
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
    final settings = context.watch<SettingsProvider>();
    final isAmoled = settings.isAmoledMode;

    return AppBar(
      backgroundColor: classicUi
          ? (isDark
              ? (isAmoled ? AppTheme.amoledBackground : AppTheme.surface)
              : AppTheme.lightSurface)
          : (isAmoled ? AppTheme.amoledBackground : Colors.transparent),
      elevation: 0,
      shape: (classicUi || isAmoled)
          ? Border(
              bottom: BorderSide(
                color: isDark
                    ? (isAmoled ? AppTheme.amoledBorder : AppTheme.border)
                    : AppTheme.lightBorder,
                width: 1.0,
              ),
            )
          : null,
      titleSpacing: 16,
      title: _isSearching
          ? _buildSearchField(context, textClr, accentClr, isDark)
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
          color: _isSearching ? accentClr : textClr,
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

  Widget _buildSearchField(
      BuildContext context, Color textClr, Color accentClr, bool isDark) {
    final isFocused = _searchFocusNode.hasFocus;
    return Theme(
      data: Theme.of(context).copyWith(
        primaryColor: accentClr,
        colorScheme: Theme.of(context).colorScheme.copyWith(
              primary: accentClr,
            ),
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: accentClr,
          selectionColor: accentClr.withValues(alpha: 0.3),
          selectionHandleColor: accentClr,
        ),
      ),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 44,
        decoration: BoxDecoration(
          color: isDark ? AppTheme.surface : AppTheme.lightSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isFocused ? accentClr : accentClr.withValues(alpha: 0.35),
            width: isFocused ? 1.8 : 1.0,
          ),
          boxShadow: isFocused
              ? [
                  BoxShadow(
                    color: accentClr.withValues(alpha: 0.3),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: TextField(
          focusNode: _searchFocusNode,
          controller: _searchController,
          autofocus: true,
          cursorColor: accentClr,
          style: TextStyle(
            color: textClr,
            fontSize: 13,
            fontFamily: 'Inter',
          ),
          onChanged: (val) {
            setState(() {});
            context.read<DownloadProvider>().setSearchQuery(val);
          },
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 18,
              color: accentClr,
            ),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.clear_rounded, size: 16, color: accentClr),
                    onPressed: () {
                      _searchController.clear();
                      context.read<DownloadProvider>().setSearchQuery('');
                      setState(() {});
                    },
                  )
                : null,
            hintText: L10n.of(context, 'search_placeholder'),
            hintStyle: TextStyle(
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
              fontSize: 12,
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
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
          padding:
              EdgeInsets.symmetric(horizontal: screenPadding(context).left),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.surface : AppTheme.lightSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color:
                    isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
                width: 1.0,
              ),
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
                const SizedBox(width: 4),
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
    final color = index == 0
        ? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue)
        : (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen);

    return Expanded(
      child: GestureDetector(
        onTap: () => _switchTab(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? color : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? Colors.white
                      : (isDark
                          ? AppTheme.textSecondary
                          : AppTheme.lightTextSecondary),
                  fontFamily: 'Space Grotesk',
                  fontSize: responsiveFontSize(context, 12),
                  fontWeight: selected ? FontWeight.bold : FontWeight.w500,
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
                        : color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: selected
                        ? null
                        : Border.all(
                            color: color.withValues(alpha: 0.2), width: 0.8),
                  ),
                  child: Text(
                    count > 99 ? '99+' : formatLocalizedNumber(context, count),
                    style: TextStyle(
                      color: selected ? Colors.white : color,
                      fontFamily: 'Space Grotesk',
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
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
      padding: EdgeInsets.symmetric(horizontal: screenPadding(context).left),
      child: Row(
        children: [
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
                          fontSize: responsiveFontSize(context, 13),
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
                          formatLocalizedNumber(context, count),
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
    final activeColor =
        getActiveFilterColor(context.read<DownloadProvider>(), isDark);
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
    final downloadProvider = context.watch<DownloadProvider>();
    final accentClr = getActiveFilterColor(downloadProvider, isDark);
    final screenType = getScreenType(context);
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
  ) async {
    final tasksToClear = provider.filteredTasks.where((task) {
      final isSeeding = task.status == DownloadStatus.completed &&
          task.isTorrent &&
          task.seedingEnabled;
      return (task.status == DownloadStatus.completed ||
              task.status == DownloadStatus.failed) &&
          !isSeeding;
    }).toList();

    final message = isRtl
        ? 'هل أنت متأكد من حذف جميع ${tasksToClear.length} سجل مكتمل؟'
        : 'Delete all ${tasksToClear.length} completed records? This cannot be undone.';

    final confirmed = await DmxConfirmDialog.show(
      context,
      title: L10n.of(context, 'clear_history'),
      message: message,
      confirmLabel: L10n.of(context, 'clear_all'),
      cancelLabel: L10n.of(context, 'cancel_btn'),
      isDestructive: true,
      icon: Icons.delete_sweep_rounded,
    );

    if (confirmed == true && context.mounted) {
      for (final task in tasksToClear) {
        await provider.deleteTask(task.id);
      }
    }
  }
}

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

class _BatchActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _BatchActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                    color: color, fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

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

    final activeFilterClr =
        getActiveFilterColor(context.watch<DownloadProvider>(), isDark);
    return DmxCardShell(
      accent: activeFilterClr,
      radius: 20,
      showRail: true,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.storage_rounded,
                  size: 14,
                  color: activeFilterClr,
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
                    fontSize: responsiveFontSize(context, 13),
                    fontWeight: FontWeight.w800,
                    fontFamily: 'Space Grotesk',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
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

  Widget _staggeredItem(BuildContext context, int index, Widget child) {
    final state = context.findAncestorStateOfType<_HomeScreenState>();
    if (state != null) {
      final delay = (0.24 + index * 0.04).clamp(0.0, 1.0);
      return state._stagger(delay, child);
    }
    return child;
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = context.watch<DownloadProvider>().isLoadingTasks;
    final provider = context.watch<DownloadProvider>();
    final isInSelectionMode = provider.isSelectionMode;

    Widget child;
    if (isLoading) {
      child = const SkeletonList(itemCount: 4, itemHeight: 110);
    } else {
      child = Selector<DownloadProvider, List<DownloadTask>>(
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
        selector: (_, p) => p.filteredTasks,
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

          final isReorderable = selectedTab == 0 &&
              provider.sortOption == SortOption.manual &&
              provider.searchQuery.isEmpty &&
              provider.categoryFilters.isEmpty;

          final Widget contentWidget;
          if (isReorderable) {
            contentWidget = ReorderableListView.builder(
              padding: EdgeInsets.symmetric(
                horizontal: screenPadding(context).left,
              ),
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              itemCount: renderItems.length,
              onReorderItem: (oldIndex, newIndex) {
                runHaptic(context.read<SettingsProvider>());
                final p = context.read<DownloadProvider>();
                if (p.statusFilter != 'All' ||
                    p.searchQuery.isNotEmpty ||
                    p.categoryFilters.isNotEmpty) {
                  debugPrint('[Queue] Reorder blocked in UI: filters active');
                  return;
                }
                final actualNewIndex =
                    oldIndex < newIndex ? newIndex + 1 : newIndex;
                p.reorderTasks(
                    provider.filteredTasks, oldIndex, actualNewIndex);
              },
              itemBuilder: (context, index) {
                final item = renderItems[index];
                final isSelected =
                    provider.selectedTaskIds.contains(item.task?.id);
                Widget card;
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
                    showDragHandle: false,
                    index: index,
                  );
                }

                card = Row(
                  children: [
                    if (isReorderable && !item.isPlaylist)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8.0),
                        child: Icon(Icons.drag_handle_rounded,
                            size: 16,
                            color: isDark
                                ? AppTheme.textMuted
                                : AppTheme.lightTextMuted),
                      ),
                    if (isInSelectionMode && !item.isPlaylist)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8.0),
                        child: Checkbox(
                          value: isSelected,
                          onChanged: (val) =>
                              provider.toggleTaskSelection(item.task!.id),
                          activeColor: isDark
                              ? AppTheme.neonBlue
                              : AppTheme.lightNeonBlue,
                        ),
                      ),
                    Expanded(child: card),
                  ],
                );

                if (!item.isPlaylist) {
                  card = GestureDetector(
                    onLongPress: () {
                      if (!isInSelectionMode) {
                        provider.toggleTaskSelection(item.task!.id);
                      }
                    },
                    onTap: () {
                      if (isInSelectionMode) {
                        provider.toggleTaskSelection(item.task!.id);
                      }
                    },
                    child: card,
                  );
                }

                return Padding(
                  key: ValueKey(item.isPlaylist
                      ? 'playlist_${item.playlistId}'
                      : item.task!.id),
                  padding: const EdgeInsets.only(bottom: 10),
                  child: RepaintBoundary(
                    child: _staggeredItem(context, index, card),
                  ),
                );
              },
            );
          } else {
            contentWidget = ListView.separated(
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
                final isSelected =
                    provider.selectedTaskIds.contains(item.task?.id);
                Widget card;
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
                    showDragHandle: false,
                    index: index,
                  );
                }

                if (!item.isPlaylist) {
                  card = Row(
                    children: [
                      if (isInSelectionMode)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 8.0),
                          child: Checkbox(
                            value: isSelected,
                            onChanged: (val) =>
                                provider.toggleTaskSelection(item.task!.id),
                            activeColor: isDark
                                ? AppTheme.neonBlue
                                : AppTheme.lightNeonBlue,
                          ),
                        ),
                      Expanded(child: card),
                    ],
                  );
                  card = GestureDetector(
                    onLongPress: () {
                      if (!isInSelectionMode) {
                        provider.toggleTaskSelection(item.task!.id);
                      }
                    },
                    onTap: () {
                      if (isInSelectionMode) {
                        provider.toggleTaskSelection(item.task!.id);
                      }
                    },
                    child: card,
                  );
                }

                return RepaintBoundary(
                  child: _staggeredItem(context, index, card),
                );
              },
            );
          }
          return Directionality(
            textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
            child: contentWidget,
          );
        },
      );
    }

    final Widget animatedChild = AnimatedSwitcher(
      duration: AppTheme.motionBase,
      child: child,
    );

    if (selectedTab == 0) {
      final provider = context.watch<DownloadProvider>();
      return RefreshIndicator(
        color: getActiveFilterColor(provider, isDark),
        backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
        strokeWidth: 2.5,
        onRefresh: () async {
          HapticFeedback.lightImpact();
          await context.read<DownloadProvider>().load(
                pauseOrphanDownloads: false,
              );
        },
        child: animatedChild,
      );
    }

    return animatedChild;
  }
}

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
    final accentClr = getActiveFilterColor(provider, isDark);
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
      child: DmxEmptyState(
        icon: icon,
        title: title,
        subtitle: subtitle,
        accentColor: accentClr,
      ),
    );
  }
}
