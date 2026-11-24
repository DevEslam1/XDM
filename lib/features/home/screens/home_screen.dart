import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/responsive.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/mixins/pausable_loop_animation.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../add_download/widgets/add_download_dialog.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/widgets/download_stats_panel.dart';
import '../../downloads/widgets/filter_chips_bar.dart';
import '../../settings/provider/settings_provider.dart';
import '../widgets/home_analytics_panel.dart';
import '../widgets/home_section_header.dart';
import '../widgets/home_segmented_tabs.dart';
import '../widgets/home_task_list.dart';
import '../widgets/home_top_bar.dart';

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
    _searchFocusNode.addListener(_onSearchFocusChanged);
    _reveal = AnimationController(
      vsync: this,
      duration: AppTheme.motionReveal,
    )..forward();
  }

  void _onSearchFocusChanged() {
    if (mounted) setState(() {});
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
    final end = (start + 0.5).clamp(0.0, 1.0);

    final fadeAnim = _fadeAnimations.putIfAbsent(
      key,
      () => _reveal.drive(
        CurveTween(curve: Interval(start, end, curve: AppTheme.motionCurve)),
      ),
    );

    final slideAnim = _slideAnimations.putIfAbsent(
      key,
      () => _reveal.drive(
        Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero).chain(
          CurveTween(curve: Interval(start, end, curve: AppTheme.motionCurve)),
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
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _reveal.dispose();
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

  void _toggleSearch() {
    triggerHaptic(context.read<SettingsProvider>());
    final nextSearching = !_isSearching;
    if (!nextSearching) {
      _searchController.clear();
      context.read<DownloadProvider>().setSearchQuery('');
      _searchFocusNode.unfocus();
    }
    setState(() => _isSearching = nextSearching);
  }

  void _clearSearch() {
    _searchController.clear();
    context.read<DownloadProvider>().setSearchQuery('');
  }

  void _openAddDownloadDialog() {
    triggerHaptic(context.read<SettingsProvider>());
    showDialog(
      context: context,
      builder: (_) => const AddDownloadDialog(),
    );
  }

  List<String> _visibleTaskIds(DownloadProvider provider) {
    return provider.filteredTasks
        .where((task) =>
            _selectedTab == 0 ? isHomeActiveTask(task) : !isHomeActiveTask(task))
        .map((task) => task.id)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Selector<
        SettingsProvider,
        ({
          bool isDarkMode,
          bool classicUi,
          String languageCode,
          bool isAmoledMode,
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
        final isAmoled = settingsState.isAmoledMode;
        final isInSelectionMode = context.select<DownloadProvider, bool>(
          (p) => p.isSelectionMode,
        );
        final accentClr = context.select<DownloadProvider, Color>(
          (p) => getActiveFilterColor(p, isDark),
        );
        final isRtl = L10n.isRtl(context);
        final horizontalPad = screenPadding(context).left;

        final PreferredSizeWidget appBar;
        if (isInSelectionMode) {
          appBar = HomeSelectionAppBar(
            isDark: isDark,
            isAmoled: isAmoled,
            accentClr: accentClr,
            visibleTaskIdsBuilder: _visibleTaskIds,
          );
        } else {
          appBar = HomeTopBar(
            isDark: isDark,
            classicUi: classicUi,
            isAmoled: isAmoled,
            accentClr: accentClr,
            isSearching: _isSearching,
            showAnalytics: _showAnalytics,
            searchController: _searchController,
            searchFocusNode: _searchFocusNode,
            onToggleAnalytics: () {
              triggerHaptic(context.read<SettingsProvider>());
              setState(() => _showAnalytics = !_showAnalytics);
            },
            onToggleSearch: _toggleSearch,
            onClearSearch: _clearSearch,
          );
        }

        return GeometricGridBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            extendBody: true,
            floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
            appBar: appBar,
            drawer: isInSelectionMode
                ? null
                : HomeNavigationDrawer(
                    isDark: isDark,
                    isAmoled: isAmoled,
                    accentClr: accentClr,
                  ),
            bottomNavigationBar: isInSelectionMode
                ? HomeBatchActionBar(
                    isDark: isDark,
                    isAmoled: isAmoled,
                    accentClr: accentClr,
                  )
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
                              const SizedBox(height: DmxTokens.spaceMd),
                              ..._buildIosBackgroundBanner(
                                isDark,
                                accentClr,
                                horizontalPad,
                              ),
                              _stagger(
                                0.0,
                                HomeSegmentedTabs(
                                  selectedTab: _selectedTab,
                                  isDark: isDark,
                                  isAmoled: isAmoled,
                                  onTabSelected: _switchTab,
                                ),
                              ),
                              const SizedBox(height: DmxTokens.spaceMd),
                              _stagger(
                                0.08,
                                AnimatedSize(
                                  duration: AppTheme.motionSlow,
                                  curve: AppTheme.motionCurve,
                                  alignment: Alignment.topCenter,
                                  child: _showAnalytics
                                      ? Padding(
                                          padding: EdgeInsets.fromLTRB(
                                            horizontalPad,
                                            2,
                                            horizontalPad,
                                            DmxTokens.spaceLg,
                                          ),
                                          child: Selector<DownloadProvider,
                                              Map<String, double>>(
                                            selector: (_, p) => p.categorySizes,
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
                                            builder:
                                                (context, categorySizes, _) =>
                                                    RepaintBoundary(
                                              child: HomeAnalyticsPanel(
                                                categorySizes: categorySizes,
                                                isDark: isDark,
                                                isAmoled: isAmoled,
                                                activeFilterClr: accentClr,
                                              ),
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ),
                              _stagger(
                                0.12,
                                AnimatedSize(
                                  duration: AppTheme.motionBase,
                                  curve: AppTheme.motionCurve,
                                  alignment: Alignment.topCenter,
                                  child: _selectedTab == 0
                                      ? Padding(
                                          padding: EdgeInsets.fromLTRB(
                                            horizontalPad,
                                            2,
                                            horizontalPad,
                                            DmxTokens.spaceLg,
                                          ),
                                          child: const DownloadStatsPanel(),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ),
                              _stagger(
                                0.16,
                                Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: horizontalPad,
                                  ),
                                  child: FilterChipsBar(
                                    isHistory: _selectedTab == 1,
                                  ),
                                ),
                              ),
                              const SizedBox(height: DmxTokens.spaceLg),
                              _stagger(
                                0.20,
                                HomeSectionHeader(
                                  selectedTab: _selectedTab,
                                  isDark: isDark,
                                  isAmoled: isAmoled,
                                  isRtl: isRtl,
                                ),
                              ),
                              const SizedBox(height: DmxTokens.spaceMd),
                            ],
                          ),
                        ),
                        SliverFillRemaining(
                          hasScrollBody: true,
                          child: HomeTaskList(
                            selectedTab: _selectedTab,
                            isDark: isDark,
                            isRtl: isRtl,
                            onClearSearch: _clearSearch,
                            onAddDownload: _openAddDownloadDialog,
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
                : _buildFAB(context, isDark, classicUi, accentClr),
          ),
        );
      },
    );
  }

  /// Persistent iOS-only banner explaining background download limitations.
  List<Widget> _buildIosBackgroundBanner(
    bool isDark,
    Color accent,
    double horizontalPad,
  ) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return const [];
    final textClr = AppTheme.textPrimaryOf(isDark);
    return [
      Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPad),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: DmxTokens.spaceMd),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: isDark ? 0.12 : 0.08),
            borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
            border: Border.all(
              color: accent.withValues(alpha: isDark ? 0.28 : 0.24),
              width: DmxTokens.borderThin,
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  L10n.of(context, 'ios_background_banner'),
                  style: TextStyle(
                    fontFamily: AppTheme.fontBody,
                    fontSize: 12,
                    color: textClr,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _buildFAB(
    BuildContext context,
    bool isDark,
    bool classicUi,
    Color accentClr,
  ) {
    final screenType = getScreenType(context);
    final isNavbarVisible =
        context.select<DownloadProvider, bool>((p) => p.isNavbarVisible);
    final showSideNav = shouldShowSideNavigation(context);
    final safeAreaBottom = MediaQuery.paddingOf(context).bottom;

    final double bottomPadding;
    if (showSideNav) {
      bottomPadding = 16.0 + safeAreaBottom;
    } else {
      switch (screenType) {
        case ScreenType.phone:
          bottomPadding = isNavbarVisible
              ? (86.0 + safeAreaBottom)
              : (16.0 + safeAreaBottom);
          break;
        case ScreenType.tablet:
          bottomPadding = isNavbarVisible
              ? (102.0 + safeAreaBottom)
              : (16.0 + safeAreaBottom);
          break;
        case ScreenType.desktop:
          bottomPadding = 16.0 + safeAreaBottom;
          break;
      }
    }

    final fgColor = AppTheme.inkOn(accentClr);

    return AnimatedPadding(
      padding: EdgeInsets.only(bottom: bottomPadding),
      duration: AppTheme.motionBase,
      curve: AppTheme.motionCurve,
      child: Container(
        decoration: classicUi
            ? null
            : BoxDecoration(
                borderRadius: BorderRadius.circular(DmxTokens.radiusLg),
                boxShadow: AppTheme.cardShadow(
                  isDark,
                  elevated: true,
                  glowColor: accentClr,
                ),
              ),
        child: Semantics(
          button: true,
          label: 'Add new download',
          hint: 'Double tap to create a new download',
          child: FloatingActionButton(
            heroTag: 'home_fab',
            backgroundColor: accentClr,
            foregroundColor: fgColor,
            elevation: classicUi ? 3 : 0,
            highlightElevation: classicUi ? 6 : 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DmxTokens.radiusLg),
              side: BorderSide(
                color: fgColor.withValues(alpha: 0.16),
                width: DmxTokens.borderThin,
              ),
            ),
            onPressed: _openAddDownloadDialog,
            child: const Icon(Icons.add_rounded, size: 24),
          ),
        ),
      ),
    );
  }
}
