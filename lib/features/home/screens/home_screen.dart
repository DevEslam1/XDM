import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/intl_formatters.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/responsive.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/mixins/pausable_loop_animation.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/skeleton_loader.dart';
// themed_snackbar removed - unused in this file
import '../../add_download/widgets/add_download_dialog.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/widgets/batch_operations_sheet.dart';
import '../../downloads/widgets/download_card.dart';
import '../../downloads/widgets/download_stats_panel.dart';
import '../../downloads/widgets/filter_chips_bar.dart';
import '../../settings/provider/settings_provider.dart';

bool _isActiveTask(DownloadTask t) {
  return (t.status != DownloadStatus.completed &&
          t.status != DownloadStatus.failed) ||
      t.isActivelySeeding;
}

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
  late final AnimationController _reveal;

  final Map<int, Animation<double>> _fadeAnimations = {};
  final Map<int, Animation<Offset>> _slideAnimations = {};

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!modernAnimationsAllowed(context)) {
      _reveal.value = 1.0;
    }
  }

  Widget _stagger(double start, Widget child) {
    if (!modernAnimationsAllowed(context)) return child;

    final key = (start * 1000).round();

    final fadeAnim = _fadeAnimations.putIfAbsent(
      key,
      () => _reveal.drive(
        CurveTween(
          curve: Interval(
            start,
            (start + 0.5).clamp(0.0, 1.0),
            curve: AppTheme.motionCurve,
          ),
        ),
      ),
    );

    final slideAnim = _slideAnimations.putIfAbsent(
      key,
      () => _reveal.drive(
        Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).chain(
          CurveTween(
            curve: Interval(
              start,
              (start + 0.5).clamp(0.0, 1.0),
              curve: AppTheme.motionCurve,
            ),
          ),
        ),
      ),
    );

    return FadeTransition(
      opacity: fadeAnim,
      child: SlideTransition(
        position: slideAnim,
        child: child,
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _reveal.dispose();
    // FIX-M9: Clear animation controller caches on dispose
    _fadeAnimations.clear();
    _slideAnimations.clear();
    super.dispose();
  }

  void _switchTab(int index) {
    if (_selectedTab == index) return;
    triggerHaptic(context.read<SettingsProvider>());
    final provider = context.read<DownloadProvider>();
    provider.setStatusFilter('All');
    provider.clearCategoryFilters();
    provider.clearTaskSelection();
    provider.setSearchQuery('');
    setState(() {
      _selectedTab = index;
      _isSearching = false;
      _searchController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Selector<
        SettingsProvider,
        ({
          bool isDarkMode,
          bool classicUi,
          String languageCode,
          bool isAmoledMode
        })>(
      selector: (_, s) => (
        isDarkMode: s.isDarkMode,
        classicUi: s.classicUi,
        languageCode: s.languageCode,
        isAmoledMode: s.isAmoledMode,
      ),
      builder: (context, settingsState, _) {
        final isDark = settingsState.isDarkMode;
        final classicUi = settingsState.classicUi;
        final textClr =
            isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
        final isInSelectionMode = context.select<DownloadProvider, bool>(
          (p) => p.isSelectionMode,
        );
        final accentClr =
            getActiveFilterColor(context.read<DownloadProvider>(), isDark);
        final isRtl = L10n.isRtl(context);

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
                    isAmoled: settingsState.isAmoledMode,
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
                  child: RepaintBoundary(
                    child: CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 12),
                              // FIX(14): iOS has no persistent background downloads
                              ..._buildIosBackgroundBanner(isDark, isRtl,
                                  context.read<DownloadProvider>()),
                              _stagger(
                                  0.0,
                                  _buildAnimatedSegmentedControl(
                                    context,
                                    isDark: isDark,
                                    isRtl: isRtl,
                                    downloadProvider:
                                        context.read<DownloadProvider>(),
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
                                              right:
                                                  screenPadding(context).left,
                                              top: 4.0,
                                              bottom: 20.0,
                                            ),
                                            child: Selector<DownloadProvider,
                                                Map<String, double>>(
                                              selector: (_, provider) =>
                                                  provider.categorySizes,
                                              shouldRebuild: (prev, next) {
                                                if (prev.length !=
                                                    next.length) {
                                                  return true;
                                                }
                                                for (final key in prev.keys) {
                                                  if (prev[key] != next[key]) {
                                                    return true;
                                                  }
                                                }
                                                return false;
                                              },
                                              builder:
                                                  (context, categorySizes, _) =>
                                                      RepaintBoundary(
                                                child:
                                                    _RedesignedAnalyticsPanel(
                                                  categorySizes: categorySizes,
                                                  settings: context
                                                      .read<SettingsProvider>(),
                                                  activeFilterClr: accentClr,
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
                                              right:
                                                  screenPadding(context).left,
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
                                        horizontal:
                                            screenPadding(context).left),
                                    child: FilterChipsBar(
                                        isHistory: _selectedTab == 1),
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
                            ],
                          ),
                        ),
                        // Task List Fill
                        SliverFillRemaining(
                          hasScrollBody: true,
                          child: _DownloadTaskList(
                            selectedTab: _selectedTab,
                            isDark: isDark,
                            isRtl: isRtl,
                            onClearSearch: () {
                              _searchController.clear();
                              context
                                  .read<DownloadProvider>()
                                  .setSearchQuery('');
                            },
                            stagger: _stagger,
                          ),
                        ),
                      ],
                    ),
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
    final count =
        context.select<DownloadProvider, int>((p) => p.selectedTaskIds.length);
    final provider = context.read<DownloadProvider>();
    final settings = context.watch<SettingsProvider>();
    final isAmoled = settings.isAmoledMode;

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
    final selectedIds =
        context.select<DownloadProvider, Set<String>>((p) => p.selectedTaskIds);
    final isAmoled =
        context.select<SettingsProvider, bool>((s) => s.isAmoledMode);

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
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
      ),
    );
  }

  /// FIX(14): persistent iOS-only banner.
  List<Widget> _buildIosBackgroundBanner(
      bool isDark, bool isRtl, DownloadProvider provider) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return const [];
    final accent = getActiveFilterColor(provider, isDark);
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
    required bool isAmoled,
    required Color textClr,
    required Color accentClr,
    required bool isRtl,
  }) {
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
          tooltip: _isSearching ? L10n.of(context, 'cancel_btn') : 'Search',
          onPressed: () {
            triggerHaptic(context.read<SettingsProvider>());
            final nextSearching = !_isSearching;
            if (!nextSearching) {
              _searchController.clear();
              context.read<DownloadProvider>().setSearchQuery('');
              _searchFocusNode.unfocus();
            }
            setState(() {
              _isSearching = nextSearching;
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
        height: 48,
        decoration: BoxDecoration(
          color: isDark ? AppTheme.surface : AppTheme.lightSurface,
          borderRadius: BorderRadius.circular(14),
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
            fontSize: 14,
            fontFamily: 'Inter',
          ),
          onChanged: (val) {
            context.read<DownloadProvider>().setSearchQuery(val);
          },
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 20,
              color: accentClr,
            ),
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _searchController,
              builder: (context, value, _) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return IconButton(
                  icon: Icon(Icons.clear_rounded, size: 18, color: accentClr),
                  onPressed: () {
                    _searchController.clear();
                    context.read<DownloadProvider>().setSearchQuery('');
                  },
                );
              },
            ),
            hintText: L10n.of(context, 'search_placeholder'),
            hintStyle: TextStyle(
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
              fontSize: 13,
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
    );
  }

  Widget _buildAnimatedSegmentedControl(
    BuildContext context, {
    required bool isDark,
    required bool isRtl,
    required DownloadProvider downloadProvider,
  }) {
    return Selector<DownloadProvider, ({int active, int history})>(
      selector: (_, p) {
        final allTasks = p.filteredTasks;
        return (
          active: allTasks.where(_isActiveTask).length,
          history: allTasks.where((t) => !_isActiveTask(t)).length,
        );
      },
      builder: (context, counts, _) {
        final activeCount = counts.active;
        final historyCount = counts.history;
        return Padding(
          padding:
              EdgeInsets.symmetric(horizontal: screenPadding(context).left),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: isDark
                  ? AppTheme.surface.withValues(alpha: 0.5)
                  : AppTheme.lightSurface.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color:
                    isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                _buildSegment(
                  context,
                  0,
                  L10n.of(context, 'active_tab'),
                  activeCount,
                  isDark,
                  downloadProvider,
                ),
                const SizedBox(width: 4),
                _buildSegment(
                  context,
                  1,
                  L10n.of(context, 'completed_tab'),
                  historyCount,
                  isDark,
                  downloadProvider,
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
    DownloadProvider downloadProvider,
  ) {
    final selected = _selectedTab == index;
    final color = getActiveFilterColor(downloadProvider, isDark);

    return Expanded(
      child: GestureDetector(
        onTap: () => _switchTab(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? color : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.4),
                      blurRadius: 8,
                      spreadRadius: -2,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
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
                  fontSize: responsiveFontSize(context, 13),
                  fontWeight: selected ? FontWeight.bold : FontWeight.w600,
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? Colors.white.withValues(alpha: 0.25)
                        : color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
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
                      fontSize: 11,
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
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final activeColor = context.select<DownloadProvider, Color>(
      (p) => getActiveFilterColor(p, isDark),
    );
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
                    L10n.of(
                      context,
                      count == 1
                          ? 'items_count_singular'
                          : 'items_count_plural',
                      args: {'count': count},
                    ),
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
                  final p = context.read<DownloadProvider>();
                  if (p.sortOption == option) {
                    p.toggleSortDirection();
                  } else {
                    p.setSortOption(option);
                  }
                },
                itemBuilder: (context) => [
                  _sortMenuItem(
                    SortOption.dateAdded,
                    L10n.of(context, 'sort_date'),
                    sortState,
                    isDark,
                    activeColor,
                  ),
                  _sortMenuItem(
                    SortOption.fileSize,
                    L10n.of(context, 'details_size'),
                    sortState,
                    isDark,
                    activeColor,
                  ),
                  _sortMenuItem(
                    SortOption.fileName,
                    L10n.of(context, 'details_filename'),
                    sortState,
                    isDark,
                    activeColor,
                  ),
                  _sortMenuItem(
                    SortOption.status,
                    L10n.of(context, 'sort_status'),
                    sortState,
                    isDark,
                    activeColor,
                  ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: (isDark ? AppTheme.glassBg : AppTheme.lightGlassBg),
                    borderRadius: BorderRadius.circular(12),
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
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Icon(Icons.sort_rounded, color: secClr, size: 16),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          Selector<DownloadProvider, int>(
            selector: (_, p) =>
                p.filteredTasks.where((t) => !_isActiveTask(t)).length,
            builder: (context, clearableLength, _) {
              if (_selectedTab != 1 || clearableLength == 0) {
                return const SizedBox.shrink();
              }
              return GestureDetector(
                onTap: () => _showClearHistoryDialog(
                    context, context.read<DownloadProvider>(), isDark, isRtl),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
                          .withValues(alpha: 0.25),
                      width: 0.8,
                    ),
                  ),
                  child: Icon(
                    Icons.delete_sweep_outlined,
                    color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                    size: 18,
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
    Color activeColor,
  ) {
    final isSelected = sortState.option == option;
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
    final downloadProvider = context.read<DownloadProvider>();
    final accentClr = getActiveFilterColor(downloadProvider, isDark);
    final screenType = getScreenType(context);
    final isNavbarVisible =
        context.select<DownloadProvider, bool>((p) => p.isNavbarVisible);
    final safeAreaBottom = MediaQuery.paddingOf(context).bottom;
    final double bottomPadding;
    switch (screenType) {
      case ScreenType.phone:
        bottomPadding =
            isNavbarVisible ? (88.0 + safeAreaBottom) : (16.0 + safeAreaBottom);
        break;
      case ScreenType.tablet:
        bottomPadding =
            isNavbarVisible ? (96.0 + safeAreaBottom) : (16.0 + safeAreaBottom);
        break;
      case ScreenType.desktop:
        bottomPadding = 16.0 + safeAreaBottom;
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
            heroTag: 'home_fab',
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
            child: const Icon(Icons.add_rounded, size: 24),
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
    final tasksToClear =
        provider.filteredTasks.where((task) => !_isActiveTask(task)).toList();

    final message = isRtl
        ? 'هل أنت متأكد من حذف جميع ${tasksToClear.length} سجل مكتمل؟'
        : 'Delete all ${tasksToClear.length} completed records? This cannot be undone.';

    final confirmed = await DmxConfirmDialog.show(
      context,
      // FIX-P1-06: Show count in confirmation title
      title: isRtl
          ? 'مسح سجل التنزيلات (${tasksToClear.length})'
          : 'Clear Download History (${tasksToClear.length} items)',
      message: message,
      confirmLabel: L10n.of(context, 'clear_all'),
      cancelLabel: L10n.of(context, 'cancel_btn'),
      isDestructive: true,
      icon: Icons.delete_sweep_rounded,
    );

    if (confirmed == true && context.mounted) {
      await provider
          .deleteMultipleTasks(tasksToClear.map((t) => t.id).toList());
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
      icon: Icon(icon, color: color, size: 22),
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
  final Color activeFilterClr;
  const _RedesignedAnalyticsPanel({
    required this.categorySizes,
    required this.settings,
    required this.activeFilterClr,
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

    final activeFilterClr = this.activeFilterClr;
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
  final VoidCallback? onClearSearch;
  final Widget Function(double, Widget) stagger;

  const _DownloadTaskList({
    required this.selectedTab,
    required this.isDark,
    required this.isRtl,
    this.onClearSearch,
    required this.stagger,
  });

  Widget _staggeredItem(BuildContext context, int index, Widget child) {
    final delay = (0.24 + index * 0.04).clamp(0.0, 1.0);
    return stagger(delay, child);
  }

  Widget _wrapSelectionMode(
      Widget card, _RenderItem item, DownloadProvider provider) {
    if (item.isPlaylist) return card;

    final isSelected = provider.selectedTaskIds.contains(item.task?.id);
    final isInSelectionMode = provider.isSelectionMode;
    return GestureDetector(
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
      child: Row(
        children: [
          if (isInSelectionMode)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8.0),
              child: Checkbox(
                value: isSelected,
                onChanged: (val) => provider.toggleTaskSelection(item.task!.id),
                activeColor:
                    isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
              ),
            ),
          Expanded(child: card),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isLoading =
        context.select<DownloadProvider, bool>((p) => p.isLoadingTasks);

    Widget child;
    if (isLoading) {
      child = const SkeletonList(
        key: ValueKey('loading'),
        itemCount: 4,
        itemHeight: 110,
      );
    } else {
      child = Selector<DownloadProvider, List<DownloadTask>>(
        selector: (_, p) => p.filteredTasks,
        shouldRebuild: (prev, next) {
          if (prev.length != next.length) return true;
          for (var i = 0; i < prev.length; i++) {
            if (prev[i].id != next[i].id || prev[i].status != next[i].status) {
              return true;
            }
          }
          return false;
        },
        builder: (context, fullList, __) {
          final provider = context.read<DownloadProvider>();
          final displayTasks = fullList
              .where((task) =>
                  selectedTab == 0 ? _isActiveTask(task) : !_isActiveTask(task))
              .toList();

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
              key: const ValueKey('empty'),
              selectedTab: selectedTab,
              isDark: isDark,
              isRtl: isRtl,
              settings: settings,
              onClearSearch: onClearSearch,
            );
          }

          final isReorderable = selectedTab == 0 &&
              provider.sortOption == SortOption.manual &&
              provider.statusFilter == 'All' &&
              provider.searchQuery.isEmpty &&
              provider.categoryFilters.isEmpty;

          final Widget contentWidget;
          if (isReorderable) {
            contentWidget = KeyedSubtree(
              key: const ValueKey('reorderable'),
              child: ReorderableListView.builder(
                // ignore: deprecated_member_use
                cacheExtent: 500.0,
                padding: EdgeInsets.only(
                  left: screenPadding(context).left,
                  right: screenPadding(context).left,
                  bottom: 84.0,
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

                  final itemToMove = renderItems[oldIndex];
                  if (itemToMove.isPlaylist) return;

                  final taskToMove = itemToMove.task!;
                  final oldTaskIndex =
                      p.filteredTasks.indexWhere((t) => t.id == taskToMove.id);
                  int newTaskIndex;
                  if (newIndex >= renderItems.length) {
                    newTaskIndex = p.filteredTasks.length - 1;
                  } else {
                    final targetItem = renderItems[newIndex];
                    if (targetItem.isPlaylist) return;
                    newTaskIndex = p.filteredTasks
                        .indexWhere((t) => t.id == targetItem.task!.id);
                  }
                  if (oldTaskIndex != -1 && newTaskIndex != -1) {
                    p.reorderTasks(p.filteredTasks, oldTaskIndex, newTaskIndex);
                  }
                },
                itemBuilder: (context, index) {
                  final item = renderItems[index];
                  Widget card;
                  if (item.isPlaylist) {
                    card = PlaylistGroupCard(
                      key: ValueKey('playlist_${item.playlistId}'),
                      playlistId: item.playlistId!,
                      title: item.title!,
                      items: item.items!,
                    );
                  } else {
                    card = Selector<DownloadProvider, DownloadTask?>(
                      key: ValueKey(item.task!.id),
                      selector: (_, p) => p.taskById(item.task!.id),
                      shouldRebuild: (prev, next) {
                        if (prev == null || next == null) return prev != next;
                        return prev.status != next.status ||
                            (prev.progress - next.progress).abs() > 0.005 ||
                            (prev.speed - next.speed).abs() > 1024 ||
                            prev.errorMessage != next.errorMessage ||
                            prev.statusMessage != next.statusMessage ||
                            prev.fileSize != next.fileSize ||
                            (prev.downloadedBytes - next.downloadedBytes).abs() > 65536;
                      },
                      builder: (_, liveTask, __) {
                        final effectiveTask = liveTask ?? item.task!;
                        return DownloadCard(
                          key: ValueKey(effectiveTask.id),
                          task: effectiveTask,
                          compact: false,
                          showDragHandle: true,
                          index: index,
                        );
                      },
                    );
                  }
                  card = _wrapSelectionMode(card, item, provider);
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
              ),
            );
          } else {
            final isMultiColumnView =
                MediaQuery.sizeOf(context).width >= 600 || isLandscape(context);
            if (isMultiColumnView) {
              contentWidget = KeyedSubtree(
                key: const ValueKey('grid'),
                child: GridView.builder(
                  // ignore: deprecated_member_use
                  cacheExtent: 500.0,
                  padding: EdgeInsets.only(
                    left: screenPadding(context).left,
                    right: screenPadding(context).left,
                    top: 4,
                    bottom: 84.0,
                  ),
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 540,
                    mainAxisExtent: 155,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 12,
                  ),
                  findChildIndexCallback: (Key key) {
                    if (key is ValueKey<String>) {
                      final keyVal = key.value;
                      final idx = renderItems.indexWhere((it) => it.isPlaylist
                          ? 'playlist_${it.playlistId}' == keyVal
                          : it.task?.id == keyVal);
                      return idx != -1 ? idx : null;
                    }
                    return null;
                  },
                  itemCount: renderItems.length,
                  itemBuilder: (context, index) {
                    final item = renderItems[index];
                    Widget card;
                    if (item.isPlaylist) {
                      card = PlaylistGroupCard(
                        key: ValueKey('playlist_${item.playlistId}'),
                        playlistId: item.playlistId!,
                        title: item.title!,
                        items: item.items!,
                      );
                    } else {
                      card = Selector<DownloadProvider, DownloadTask?>(
                        key: ValueKey(item.task!.id),
                        selector: (_, p) => p.taskById(item.task!.id),
                        shouldRebuild: (prev, next) {
                          if (prev == null || next == null) return prev != next;
                          return prev.status != next.status ||
                              (prev.progress - next.progress).abs() > 0.005 ||
                              (prev.speed - next.speed).abs() > 1024 ||
                              prev.errorMessage != next.errorMessage ||
                              prev.statusMessage != next.statusMessage ||
                              prev.fileSize != next.fileSize ||
                              (prev.downloadedBytes - next.downloadedBytes).abs() > 65536;
                        },
                        builder: (_, liveTask, __) {
                          final effectiveTask = liveTask ?? item.task!;
                          return DownloadCard(
                            key: ValueKey(effectiveTask.id),
                            task: effectiveTask,
                            compact: true,
                            showDragHandle: false,
                            index: index,
                          );
                        },
                      );
                    }
                    if (!item.isPlaylist) {
                      card = _wrapSelectionMode(card, item, provider);
                    }
                    return RepaintBoundary(
                      child: _staggeredItem(context, index, card),
                    );
                  },
                ),
              );
            } else {
              contentWidget = KeyedSubtree(
                key: const ValueKey('list'),
                child: ListView.separated(
                  // ignore: deprecated_member_use
                  cacheExtent: 500.0,
                  padding: EdgeInsets.only(
                    left: screenPadding(context).left,
                    right: screenPadding(context).left,
                    bottom: 84.0,
                  ),
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  findItemIndexCallback: (Key key) {
                    if (key is ValueKey<String>) {
                      final keyVal = key.value;
                      final idx = renderItems.indexWhere((it) => it.isPlaylist
                          ? 'playlist_${it.playlistId}' == keyVal
                          : it.task?.id == keyVal);
                      return idx != -1 ? idx : null;
                    }
                    return null;
                  },
                  itemCount: renderItems.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = renderItems[index];
                    Widget card;
                    if (item.isPlaylist) {
                      card = PlaylistGroupCard(
                        key: ValueKey('playlist_${item.playlistId}'),
                        playlistId: item.playlistId!,
                        title: item.title!,
                        items: item.items!,
                      );
                    } else {
                      card = Selector<DownloadProvider, DownloadTask?>(
                        key: ValueKey(item.task!.id),
                        selector: (_, p) => p.taskById(item.task!.id),
                        shouldRebuild: (prev, next) {
                          if (prev == null || next == null) return prev != next;
                          return prev.status != next.status ||
                              (prev.progress - next.progress).abs() > 0.005 ||
                              (prev.speed - next.speed).abs() > 1024 ||
                              prev.errorMessage != next.errorMessage ||
                              prev.statusMessage != next.statusMessage ||
                              prev.fileSize != next.fileSize ||
                              (prev.downloadedBytes - next.downloadedBytes).abs() > 65536;
                        },
                        builder: (_, liveTask, __) {
                          final effectiveTask = liveTask ?? item.task!;
                          return DownloadCard(
                            key: ValueKey(effectiveTask.id),
                            task: effectiveTask,
                            compact: true,
                            showDragHandle: false,
                            index: index,
                          );
                        },
                      );
                    }
                    if (!item.isPlaylist) {
                      card = _wrapSelectionMode(card, item, provider);
                    }
                    return RepaintBoundary(
                      child: _staggeredItem(context, index, card),
                    );
                  },
                ),
              );
            }
          }
          final Widget bodyWithReconcileIndicator;
          if (provider.isReconciling) {
            bodyWithReconcileIndicator = Column(
              children: [
                const SizedBox(
                  height: 3,
                  child: LinearProgressIndicator(
                    value: null,
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation<Color>(AppTheme.neonGreen),
                  ),
                ),
                Expanded(child: contentWidget),
              ],
            );
          } else {
            bodyWithReconcileIndicator = contentWidget;
          }

          return Directionality(
            textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
            child: bodyWithReconcileIndicator,
          );
        },
      );
    }

    final Widget animatedChild = AnimatedSwitcher(
      duration: AppTheme.motionBase,
      child: child,
    );

    if (selectedTab == 0) {
      final provider = context.read<DownloadProvider>();
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
    super.key,
    required this.selectedTab,
    required this.isDark,
    required this.isRtl,
    required this.settings,
    this.onClearSearch,
  });

  @override
  Widget build(BuildContext context) {
    final query =
        context.select<DownloadProvider, String>((p) => p.searchQuery);
    final accentClr =
        getActiveFilterColor(context.read<DownloadProvider>(), isDark);
    if (query.isNotEmpty) {
      final isLandscape =
          MediaQuery.of(context).orientation == Orientation.landscape;

      return Center(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.symmetric(
            horizontal: 24.0,
            vertical: isLandscape ? 12.0 : 32.0,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: EdgeInsets.all(isLandscape ? 14 : 20),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accentClr.withValues(alpha: 0.06),
                  border: Border.all(color: accentClr.withValues(alpha: 0.15)),
                ),
                child: Icon(
                  Icons.search_off_rounded,
                  size: isLandscape ? 28 : 36,
                  color: accentClr.withValues(alpha: 0.6),
                ),
              ),
              SizedBox(height: isLandscape ? 8 : 16),
              Text(
                '${L10n.of(context, 'no_results_for')} "$query"',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color:
                      isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: isLandscape ? 13 : 14,
                ),
              ),
              SizedBox(height: isLandscape ? 8 : 16),
              TextButton.icon(
                onPressed: () {
                  onClearSearch?.call();
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
