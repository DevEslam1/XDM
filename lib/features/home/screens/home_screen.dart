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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with HapticHelper {
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  bool _showAnalytics = false;
  int _selectedTab = 0; // 0: Active, 1: Completed

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Selector<SettingsProvider, ({bool isDarkMode, bool classicUi})>(
      selector: (_, s) => (isDarkMode: s.isDarkMode, classicUi: s.classicUi),
      builder: (context, settingsState, _) {
        final isDark = settingsState.isDarkMode;
        final classicUi = settingsState.classicUi;
        final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
        final accentClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
        final isRtl = L10n.isRtl(context);

        return GeometricGridBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
        appBar: AppBar(
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
          title: _isSearching
              ? Container(
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF0F0F16)
                        : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isDark
                          ? const Color(0x15FFFFFF)
                          : const Color(0x0D000000),
                      width: 0.8,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    controller: _searchController,
                    autofocus: true,
                    style: TextStyle(color: textClr, fontSize: 16),
                    decoration: InputDecoration(
                      hintText: L10n.of(
                        context,
                        'search_placeholder',
                      ).toUpperCase(),
                      hintStyle: TextStyle(
                        color: isDark
                            ? AppTheme.textMuted
                            : AppTheme.lightTextMuted,
                        fontSize: 14,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onChanged: (val) =>
                        context.read<DownloadProvider>().setSearchQuery(val),
                  ),
                )
              : Text(
                  'XDM',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: textClr,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    fontSize: 18,
                  ),
                ),
          actions: [
            if (!_isSearching)
              IconButton(
                icon: Icon(
                  _showAnalytics ? Icons.analytics : Icons.analytics_outlined,
                  color: _showAnalytics ? accentClr : textClr,
                ),
                tooltip: isRtl ? 'تحليل التخزين' : 'STORAGE ANALYTICS',
                onPressed: () {
                  triggerHaptic(context.read<SettingsProvider>());
                  setState(() {
                    _showAnalytics = !_showAnalytics;
                  });
                },
              ),
            IconButton(
              icon: Icon(
                _isSearching ? Icons.close : Icons.search,
                color: textClr,
              ),
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
        ),
        body: SafeArea(
          child: Center(
            child: SizedBox(
              width: contentMaxWidth(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Sliding Segmented Tab Selector
                  _buildSegmentedControl(context, isDark, isRtl),

                  // Storage & Category Analytics Panel
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOutCubic,
                    child: _showAnalytics
                        ? Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                              vertical: 8.0,
                            ),
                            child: Selector<DownloadProvider, Map<String, double>>(
                              selector: (_, provider) => provider.categorySizes,
                              shouldRebuild: (prev, next) {
                                if (prev.length != next.length) return true;
                                for (final key in prev.keys) {
                                  if (prev[key] != next[key]) return true;
                                }
                                return false;
                              },
                              builder: (context, categorySizes, _) =>
                                  _DonutChartPanel(
                                    categorySizes: categorySizes,
                                    settings: context.read<SettingsProvider>(),
                                  ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),

                  // Download Speed Statistics (only show for Active Downloads)
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOutCubic,
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
                  const SizedBox(height: 16),

                  // Title "DOWNLOADS OVERVIEW"
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Text(
                      _selectedTab == 0
                          ? (isRtl ? 'التنزيلات النشطة' : 'ACTIVE DOWNLOADS')
                          : (isRtl
                                ? 'سجل التنزيلات المكتملة'
                                : 'COMPLETED DOWNLOADS'),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: isDark
                            ? AppTheme.textSecondary
                            : AppTheme.lightTextSecondary,
                        fontSize: 10,
                        letterSpacing: 1.0,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Controls Row: Sort Option on the Left, Delete Sweep/Task count on the Right
                  _DownloadControlsRow(
                    selectedTab: _selectedTab,
                    isDark: isDark,
                    isRtl: isRtl,
                    settings: context.read<SettingsProvider>(),
                  ),
                  const SizedBox(height: 10),

                  // Download Tasks list with Pull-to-Refresh
                  Expanded(
                    child: _DownloadTaskList(
                      selectedTab: _selectedTab,
                      isDark: isDark,
                      isRtl: isRtl,
                      settings: context.read<SettingsProvider>(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        floatingActionButton: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom + 8.0,
          ),
          child: classicUi
              ? FloatingActionButton(
                  heroTag: null,
                  backgroundColor: isDark
                      ? AppTheme.neonViolet
                      : AppTheme.lightNeonViolet,
                  foregroundColor: isDark
                      ? AppTheme.background
                      : AppTheme.lightBackground,
                  shape: const CircleBorder(
                    side: BorderSide(color: Colors.white24, width: 0.8),
                  ),
                  child: const Icon(Icons.add, size: 28),
                  onPressed: () {
                    triggerHaptic(context.read<SettingsProvider>());
                    showDialog(
                      context: context,
                      builder: (_) => const AddDownloadDialog(),
                    );
                  },
                )
              : Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color:
                            (isDark
                                    ? AppTheme.neonViolet
                                    : AppTheme.lightNeonViolet)
                                .withValues(alpha: 0.3),
                        blurRadius: 16.0,
                        spreadRadius: 0,
                      ),
                    ],
                  ),
                  child: FloatingActionButton(
                    heroTag: null,
                    backgroundColor: isDark
                        ? AppTheme.neonViolet
                        : AppTheme.lightNeonViolet,
                    foregroundColor: isDark
                        ? AppTheme.background
                        : AppTheme.lightBackground,
                    shape: const CircleBorder(
                      side: BorderSide(color: Colors.white24, width: 0.8),
                    ),
                    child: const Icon(Icons.add, size: 28),
                    onPressed: () {
                      triggerHaptic(context.read<SettingsProvider>());
                      showDialog(
                        context: context,
                        builder: (_) => const AddDownloadDialog(),
                      );
                    },
                  ),
                ),
        ),
      ),
    );
      },
    );
  }

  Widget _buildSegmentedControl(BuildContext context, bool isDark, bool isRtl) {
    final activeClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final inactiveClr = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final provider = Provider.of<DownloadProvider>(context, listen: false);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      height: 44,
      decoration: BoxDecoration(
        color: settings.classicUi
            ? (isDark ? AppTheme.surface : AppTheme.lightSurface)
            : (isDark ? const Color(0x1A000000) : const Color(0x0A000000)),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: settings.classicUi
              ? (isDark ? AppTheme.border : AppTheme.lightBorder)
              : (isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () {
                triggerHaptic(settings);
                setState(() {
                  _selectedTab = 0;
                });
                provider.setStatusFilter('All');
              },
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _selectedTab == 0
                      ? (settings.classicUi
                            ? (isDark
                                  ? AppTheme.background
                                  : AppTheme.lightBackground)
                            : (isDark
                                  ? AppTheme.glassBg
                                  : AppTheme.lightGlassBg))
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(22),
                  border: _selectedTab == 0
                      ? Border.all(
                          color: settings.classicUi
                              ? (isDark
                                    ? AppTheme.border
                                    : AppTheme.lightBorder)
                              : activeClr.withValues(alpha: 0.3),
                          width: 0.8,
                        )
                      : null,
                ),
                child: Text(
                  isRtl ? 'النشطة' : 'ACTIVE',
                  style: TextStyle(
                    color: _selectedTab == 0 ? activeClr : inactiveClr,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () {
                triggerHaptic(settings);
                setState(() {
                  _selectedTab = 1;
                });
                provider.setStatusFilter('All');
              },
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _selectedTab == 1
                      ? (settings.classicUi
                            ? (isDark
                                  ? AppTheme.background
                                  : AppTheme.lightBackground)
                            : (isDark
                                  ? AppTheme.glassBg
                                  : AppTheme.lightGlassBg))
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(22),
                  border: _selectedTab == 1
                      ? Border.all(
                          color: settings.classicUi
                              ? (isDark
                                    ? AppTheme.border
                                    : AppTheme.lightBorder)
                              : activeClr.withValues(alpha: 0.3),
                          width: 0.8,
                        )
                      : null,
                ),
                child: Text(
                  isRtl ? 'المكتملة' : 'COMPLETED',
                  style: TextStyle(
                    color: _selectedTab == 1 ? activeClr : inactiveClr,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadControlsRow extends StatelessWidget {
  final int selectedTab;
  final bool isDark;
  final bool isRtl;
  final SettingsProvider settings;

  const _DownloadControlsRow({
    required this.selectedTab,
    required this.isDark,
    required this.isRtl,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final provider = context.read<DownloadProvider>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Selector<DownloadProvider, ({SortOption option, bool ascending})>(
            selector: (_, p) => (option: p.sortOption, ascending: p.sortAscending),
            builder: (context, sortState, _) {
              return PopupMenuButton<SortOption>(
                tooltip: 'SORT CHANNELS',
                color: isDark ? AppTheme.surface : AppTheme.lightSurface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: isDark
                        ? AppTheme.glassBorder
                        : AppTheme.lightGlassBorder,
                    width: 0.6,
                  ),
                ),
                onSelected: (option) {
                  final p = context.read<DownloadProvider>();
                  if (p.sortOption == option) {
                    p.toggleSortDirection();
                  } else {
                    p.setSortOption(option);
                  }
                },
                itemBuilder: (context) => [
                  _buildSortMenuItem(
                    option: SortOption.dateAdded,
                    label: L10n.of(context, 'sort_date'),
                    currentOption: sortState.option,
                    ascending: sortState.ascending,
                    isDark: isDark,
                  ),
                  _buildSortMenuItem(
                    option: SortOption.fileSize,
                    label: L10n.of(context, 'details_size'),
                    currentOption: sortState.option,
                    ascending: sortState.ascending,
                    isDark: isDark,
                  ),
                  _buildSortMenuItem(
                    option: SortOption.fileName,
                    label: L10n.of(context, 'details_filename'),
                    currentOption: sortState.option,
                    ascending: sortState.ascending,
                    isDark: isDark,
                  ),
                  _buildSortMenuItem(
                    option: SortOption.status,
                    label: L10n.of(context, 'sort_status'),
                    currentOption: sortState.option,
                    ascending: sortState.ascending,
                    isDark: isDark,
                  ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0x1F000000)
                        : const Color(0x0A000000),
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
                      Icon(Icons.sort_rounded, color: textClr, size: 14),
                      const SizedBox(width: 6),
                      Text(
                        isRtl ? 'فرز' : 'SORT',
                        style: TextStyle(
                          color: textClr,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          Selector<DownloadProvider, int>(
            selector: (_, p) => p.filteredTasks.length,
            builder: (context, length, _) {
              if (selectedTab == 1 && length > 0) {
                return IconButton(
                  icon: Icon(
                    Icons.delete_sweep_outlined,
                    color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                    size: 20,
                  ),
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                  tooltip: isRtl ? 'مسح كل السجل' : 'CLEAR ALL HISTORY',
                  onPressed: () =>
                      _showClearHistoryDialog(context, provider, isDark, isRtl),
                );
              }
              return Text(
                '$length ${isRtl ? 'ملفات' : 'TASKS'}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                  fontSize: 10,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

PopupMenuItem<SortOption> _buildSortMenuItem({
  required SortOption option,
  required String label,
  required SortOption currentOption,
  required bool ascending,
  required bool isDark,
}) {
  final isSelected = currentOption == option;
  final activeColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
  final textColor = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

  return PopupMenuItem<SortOption>(
    value: option,
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
            ascending ? Icons.arrow_upward : Icons.arrow_downward,
            color: activeColor,
            size: 16,
          ),
      ],
    ),
  );
}

class _DownloadTaskList extends StatelessWidget {
  final int selectedTab;
  final bool isDark;
  final bool isRtl;
  final SettingsProvider settings;

  const _DownloadTaskList({
    required this.selectedTab,
    required this.isDark,
    required this.isRtl,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    return Selector<DownloadProvider, List<DownloadTask>>(
      shouldRebuild: (prev, next) {
        if (prev.length != next.length) return true;
        for (var i = 0; i < prev.length; i++) {
          if (prev[i].id != next[i].id ||
              prev[i].status != next[i].status ||
              prev[i].downloadedBytes != next[i].downloadedBytes ||
              prev[i].speed != next[i].speed ||
              prev[i].eta != next[i].eta ||
              !listEquals(prev[i].chunks, next[i].chunks)) {
            return true;
          }
        }
        return false;
      },
      selector: (_, provider) => provider.filteredTasks,
      builder: (context, fullList, _) {
        final displayTasks = fullList.where((task) {
          final isSeeding =
              task.status == DownloadStatus.completed &&
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

        if (displayTasks.isEmpty) {
          return _EmptyState(
            selectedTab: selectedTab,
            isDark: isDark,
            isRtl: isRtl,
            settings: settings,
          );
        }

        return RefreshIndicator(
          color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          onRefresh: () async {
            await context.read<DownloadProvider>().load(
              pauseOrphanDownloads: false,
            );
            if (context.mounted) {
              ThemedSnackbar.show(
                context,
                message: isRtl
                    ? 'تم إعادة تحميل سجلات الاتصال'
                    : 'Transmission logs reloaded',
                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                icon: Icons.sync,
                isDarkMode: isDark,
              );
            }
          },
          child: isTablet(context)
              ? GridView.builder(
                  padding: EdgeInsets.symmetric(
                    horizontal: screenPadding(context).left,
                    vertical: 8,
                  ),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: gridChildAspectRatio(context, columns: 2),
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  itemCount: displayTasks.length,
                  itemBuilder: (context, index) => RepaintBoundary(
                    child: DownloadCard(
                      task: displayTasks[index],
                      compact: true,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.symmetric(
                    horizontal: screenPadding(context).left,
                  ),
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  itemCount: displayTasks.length,
                  itemBuilder: (context, index) => RepaintBoundary(
                    child: DownloadCard(
                      task: displayTasks[index],
                      compact: true,
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final int selectedTab;
  final bool isDark;
  final bool isRtl;
  final SettingsProvider settings;

  const _EmptyState({
    required this.selectedTab,
    required this.isDark,
    required this.isRtl,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    final icon = selectedTab == 1
        ? Icons.history_toggle_off_outlined
        : Icons.portable_wifi_off_outlined;
    final title = selectedTab == 1
        ? L10n.of(context, 'history_empty')
        : L10n.of(context, 'empty_transmissions');
    final subtitle = selectedTab == 1
        ? (isRtl
              ? 'سيتم تصنيف السجلات المكتملة هنا.'
              : 'Finished downloads will be cataloged here.')
        : (isRtl
              ? 'أدخل رابطاً لبدء التنزيل.'
              : 'Insert a URL to start downloading.');

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
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
            ),
            child: Icon(
              icon,
              size: 40,
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: isDark
                  ? AppTheme.textSecondary
                  : AppTheme.lightTextSecondary,
              letterSpacing: 1.0,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _DonutChartPanel extends StatelessWidget {
  final Map<String, double> categorySizes;
  final SettingsProvider settings;

  const _DonutChartPanel({required this.categorySizes, required this.settings});

  @override
  Widget build(BuildContext context) {
    final isDark = settings.isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final isRtl = L10n.isRtl(context);
    final sizes = categorySizes;
    final totalSizeMb = sizes.values.fold(0.0, (sum, val) => sum + val);

    final categoryCards = [
      {
        'name': 'Video',
        'color': isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
      },
      {
        'name': 'Audio',
        'color': isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
      },
      {
        'name': 'Document',
        'color': isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
      },
      {
        'name': 'Archive',
        'color': isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
      },
      {'name': 'APK', 'color': const Color(0xFFF15BB5)},
      {
        'name': 'Other',
        'color': isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
      },
    ];

    final totalSizeText = totalSizeMb >= 1024
        ? '${(totalSizeMb / 1024).toStringAsFixed(2)} GB'
        : '${totalSizeMb.toStringAsFixed(1)} MB';

    final hasNoData = totalSizeMb == 0.0;
    final activeCategoryNames = hasNoData
        ? <String>[]
        : categoryCards
              .where((card) => (sizes[card['name']] ?? 0.0) > 0)
              .map<String>((card) => card['name'] as String)
              .toList();

    final sections = hasNoData
        ? [
            PieChartSectionData(
              color: isDark ? AppTheme.border : AppTheme.lightBorder,
              value: 1.0,
              radius: 16,
              title: '',
            ),
          ]
        : activeCategoryNames.map((name) {
            final card = categoryCards.firstWhere((c) => c['name'] == name);
            final sizeMb = sizes[name] ?? 0.0;
            final percentage = totalSizeMb > 0
                ? (sizeMb / totalSizeMb) * 100
                : 0.0;
            return PieChartSectionData(
              color: card['color'] as Color,
              value: sizeMb,
              radius: 16,
              title: percentage >= 10
                  ? '${percentage.toStringAsFixed(0)}%'
                  : '',
              titleStyle: const TextStyle(
                color: Colors.white,
                fontSize: 8,
                fontWeight: FontWeight.bold,
              ),
            );
          }).toList();

    final isTabletDevice = isTablet(context);
    final containerHeight = isTabletDevice ? 120.0 : 145.0;

    final chartBody = Container(
      width: double.infinity,
      height: containerHeight,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PieChart(
                  PieChartData(
                    pieTouchData: PieTouchData(
                      touchCallback: (FlTouchEvent event, pieTouchResponse) {
                        if (!event.isInterestedForInteractions ||
                            pieTouchResponse?.touchedSection == null) {
                          return;
                        }
                        final touchedIndex = pieTouchResponse!
                            .touchedSection!
                            .touchedSectionIndex;
                        if (touchedIndex >= 0 &&
                            touchedIndex < activeCategoryNames.length) {
                          context.read<DownloadProvider>().toggleCategoryFilter(
                            activeCategoryNames[touchedIndex],
                          );
                        }
                      },
                    ),
                    sections: sections,
                    centerSpaceRadius: 28,
                    sectionsSpace: 2.5,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isRtl ? 'الإجمالي' : 'TOTAL',
                      style: TextStyle(
                        color: mutedClr,
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    Text(
                      totalSizeText,
                      style: TextStyle(
                        color: textClr,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
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
                    child: Text(
                      isRtl ? 'لا توجد بيانات' : 'NO DATA AVAILABLE',
                      style: TextStyle(
                        color: mutedClr,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  )
                : isTabletDevice
                    ? Row(
                        children: [
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: categoryCards.take(3).map((card) {
                                return _buildLegendItem(
                                  card,
                                  sizes,
                                  totalSizeMb,
                                  textClr,
                                  isDark,
                                  isRtl,
                                );
                              }).toList(),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: categoryCards.skip(3).map((card) {
                                return _buildLegendItem(
                                  card,
                                  sizes,
                                  totalSizeMb,
                                  textClr,
                                  isDark,
                                  isRtl,
                                );
                              }).toList(),
                            ),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: categoryCards.map((card) {
                          return _buildLegendItem(
                            card,
                            sizes,
                            totalSizeMb,
                            textClr,
                            isDark,
                            isRtl,
                          );
                        }).toList(),
                      ),
          ),
        ],
      ),
    );

    return chartBody;
  }

  Widget _buildLegendItem(
    Map<String, dynamic> card,
    Map<String, double> sizes,
    double totalSizeMb,
    Color textClr,
    bool isDark,
    bool isRtl,
  ) {
    final name = card['name'] as String;
    final sizeMb = sizes[name] ?? 0.0;
    final percentage = totalSizeMb > 0 ? (sizeMb / totalSizeMb) * 100 : 0.0;
    final sizeText = sizeMb >= 1024
        ? '${(sizeMb / 1024).toStringAsFixed(1)}G'
        : '${sizeMb.toStringAsFixed(0)}M';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: card['color'] as Color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isRtl ? _translateCat(name) : name,
              style: TextStyle(
                color: textClr,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${percentage.toStringAsFixed(0)}%',
            style: TextStyle(
              color: card['color'] as Color,
              fontSize: 9,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            sizeText,
            style: TextStyle(
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
              fontSize: 9,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
            ),
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

void _showClearHistoryDialog(
  BuildContext context,
  DownloadProvider provider,
  bool isDark,
  bool isRtl,
) {
  final surfaceClr = isDark ? AppTheme.surface : AppTheme.lightSurface;
  final glassBorder = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
  final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
  final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

  showDialog(
    context: context,
    builder: (ctx) {
      final tasksToClear = provider.filteredTasks.where((task) {
        final isSeeding =
            task.status == DownloadStatus.completed &&
            task.isTorrent &&
            task.seedingEnabled;
        return (task.status == DownloadStatus.completed ||
                task.status == DownloadStatus.failed) &&
            !isSeeding;
      }).toList();

      return Directionality(
        textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
        child: AlertDialog(
          backgroundColor: surfaceClr.withValues(alpha: 0.92),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: glassBorder, width: 0.8),
          ),
          title: Text(
            isRtl ? 'مسح سجل التاريخ' : 'CLEAR HISTORY LOGS',
            style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
              color: redClr,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          content: Text(
            isRtl
                ? 'هل أنت متأكد من حذف جميع سجلات التاريخ البالغ عددها ${tasksToClear.length}؟'
                : 'Are you sure you want to delete all ${tasksToClear.length} completed history records?',
            style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(color: secClr),
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                L10n.of(ctx, 'cancel_btn'),
                style: TextStyle(color: secClr),
              ),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
            TextButton(
              style: TextButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                isRtl ? 'مسح الكل' : 'CLEAR ALL',
                style: TextStyle(color: redClr, fontWeight: FontWeight.bold),
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
