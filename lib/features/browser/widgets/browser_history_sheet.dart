import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/database_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';
import '../../../shared/widgets/skeleton_loader.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/history_export_service.dart';

class BrowserHistorySheet extends StatefulWidget {
  static final _log = Logger('BrowserHistorySheet');
  const BrowserHistorySheet({super.key});

  static Future<String?> show(BuildContext context) {
    return showDmxModalBottomSheet<String>(
      context: context,
      builder: (context) => const BrowserHistorySheet(),
    );
  }

  @override
  State<BrowserHistorySheet> createState() => _BrowserHistorySheetState();
}

class _BrowserHistorySheetState extends State<BrowserHistorySheet>
    with TickerProviderStateMixin, HapticHelper {
  int _selectedTab = 0; // 0: Surfing, 1: Downloads
  List<Map<String, dynamic>> _surfingHistory = [];
  bool _isLoadingHistory = true;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _debounceTimer;
  final FocusNode _focusNode = FocusNode();

  // FIX(P11): Paginate the surfing-history list — render 50 entries initially
  // and reveal more on scroll instead of building the whole list at once.
  static const _historyPageSize = 50;
  int _visibleHistoryCount = _historyPageSize;
  ScrollController? _attachedScrollController;

  late final AnimationController _tabSlide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );

  @override
  void initState() {
    super.initState();
    _loadSurfingHistory();
    _searchController.addListener(() {
      if (_debounceTimer?.isActive ?? false) _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) {
          setState(
            () => _searchQuery = _searchController.text.toLowerCase().trim(),
          );
          _loadSurfingHistory();
        }
      });
    });
    _focusNode.addListener(_onFocusChanged);
  }

  void _onScroll() {
    if (!mounted) return;
    final controller = _attachedScrollController;
    if (controller == null || !controller.hasClients) return;
    final position = controller.position;
    final nearBottom = position.maxScrollExtent - position.pixels < 400;
    if (nearBottom) {
      final next = _visibleHistoryCount + _historyPageSize;
      if (mounted && next > _visibleHistoryCount) {
        setState(() => _visibleHistoryCount = next);
      }
    }
  }

  void _attachPagination(ScrollController controller) {
    if (_attachedScrollController == controller) return;
    _attachedScrollController?.removeListener(_onScroll);
    _attachedScrollController = controller;
    controller.addListener(_onScroll);
  }

  void _onFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _attachedScrollController?.removeListener(_onScroll);
    _focusNode.dispose();
    _searchController.dispose();
    _debounceTimer?.cancel();
    _tabSlide.dispose();
    super.dispose();
  }

  void _switchTab(int index) {
    if (_selectedTab == index) return;
    HapticHelper.triggerHaptic(context.read<SettingsProvider>());
    if (index == 1) {
      _tabSlide.forward();
    } else {
      _tabSlide.reverse();
    }
    setState(() => _selectedTab = index);
  }

  String _formatTimestamp(dynamic value) {
    if (value == null) return '';
    if (value is num) {
      final ms = value.toInt();
      if (ms <= 0) return '';
      return _formatDateTime(DateTime.fromMillisecondsSinceEpoch(ms));
    }
    if (value is String && value.isNotEmpty) {
      try {
        final dt = DateTime.parse(value);
        if (dt.millisecondsSinceEpoch <= 0) return '';
        return _formatDateTime(dt);
      } catch (e, st) {
        Logger('browser_history_sheet')
            .warning('[browser_history_sheet] operation failed', e, st);
        return '';
      }
    }
    return '';
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _extractHost(String url) {
    final uri = Uri.tryParse(url);
    var host = uri?.host ?? '';
    if (host.startsWith('www.')) host = host.substring(4);
    return host.isNotEmpty ? host : url;
  }

  Future<void> _exportHistoryToJson() async {
    final settings = context.read<SettingsProvider>();
    HapticHelper.triggerHaptic(settings);
    try {
      final List<Map<String, dynamic>> exportData = [];
      if (_selectedTab == 0) {
        exportData.addAll(_surfingHistory);
      } else {
        final provider = context.read<DownloadProvider>();
        for (final task in provider.tasks) {
          exportData.add({
            'fileName': task.fileName,
            'url': task.url,
            'fileSize': task.fileSize,
            'status': task.status.name,
            'category': task.category,
            'createdAt': task.createdAt.toIso8601String(),
            'completedAt': task.completedAt?.toIso8601String(),
          });
        }
      }
      final name = _selectedTab == 0
          ? 'xdm_surfing_history.json'
          : 'xdm_download_history.json';
      final subject =
          _selectedTab == 0 ? 'XDM Surfing History' : 'XDM Download History';
      final file =
          await HistoryExportService.instance.exportToJson(exportData, name);
      await HistoryExportService.instance.shareHistoryFile(file, subject);
    } catch (e) {
      if (mounted) {
        final isDark = context.read<SettingsProvider>().isDarkMode;
        ThemedSnackbar.show(
          context,
          message: '${L10n.of(context, 'browser_export_failed')}: $e',
          color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
          icon: Icons.error_outline,
          isDarkMode: isDark,
        );
      }
    }
  }

  Future<void> _loadSurfingHistory() async {
    try {
      final db = context.read<DatabaseService>();
      final h = await db.loadBrowserHistory(
        max: 500,
        searchQuery: _searchQuery.isNotEmpty ? _searchQuery : null,
      );
      if (!mounted) return;
      setState(() {
        _surfingHistory = h;
        _visibleHistoryCount = _historyPageSize;
        _isLoadingHistory = false;
      });
    } catch (e) {
      BrowserHistorySheet._log.warning('[HistorySheet] Error: $e');
      if (!mounted) return;
      setState(() {
        _surfingHistory = [];
        _visibleHistoryCount = _historyPageSize;
        _isLoadingHistory = false;
      });
    }
  }

  Future<void> _deleteHistoryItem(int id) async {
    try {
      final db = context.read<DatabaseService>();
      await db.deleteBrowserHistory(id);
      _loadSurfingHistory();
    } catch (e) {
      BrowserHistorySheet._log.warning('[HistorySheet] Error: $e');
    }
  }

  Future<void> _clearAllSurfingHistory() async {
    try {
      final db = context.read<DatabaseService>();
      await db.clearBrowserHistory();
      _loadSurfingHistory();
    } catch (e) {
      BrowserHistorySheet._log.warning('[HistorySheet] Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isAmoled = settings.isAmoledMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);
    final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);

    final downloadTasks =
        context.select<DownloadProvider, List<DownloadTask>>((p) => p.tasks);

    return Directionality(
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.74,
        maxChildSize: 0.94,
        minChildSize: 0.42,
        builder: (context, controller) {
          return DmxSheetContainer(
            scrollable: false,
            isDark: isDark,
            isAmoled: isAmoled,
            maxHeightFraction: 1.0,
            padding: EdgeInsets.zero,
            showHeaderDivider: false,
            header: DmxSheetHeader(
              isDark: isDark,
              icon: _selectedTab == 0
                  ? Icons.history_rounded
                  : Icons.download_rounded,
              accentColor: accent,
              title: _selectedTab == 0
                  ? L10n.of(context, 'browser_history_title')
                  : L10n.of(context, 'browser_download_history'),
              onClose: () {
                HapticHelper.triggerHaptic(settings);
                Navigator.pop(context);
              },
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _HeaderAction(
                    icon: Icons.ios_share_rounded,
                    tooltip: L10n.of(context, 'browser_export_json'),
                    isDark: isDark,
                    isAmoled: isAmoled,
                    onTap: _exportHistoryToJson,
                  ),
                  if (_selectedTab == 0 && _surfingHistory.isNotEmpty)
                    _HeaderAction(
                      icon: Icons.delete_sweep_outlined,
                      tooltip: L10n.of(context, 'browser_clear_history_btn'),
                      isDark: isDark,
                      isAmoled: isAmoled,
                      danger: true,
                      onTap: () {
                        HapticHelper.triggerHaptic(settings);
                        _showClearHistoryConfirmation(settings);
                      },
                    ),
                ],
              ),
            ),
            child: Column(
              children: [
                // Sliding segmented tab selector
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    DmxTokens.sheetHorizontalPadding,
                    2,
                    DmxTokens.sheetHorizontalPadding,
                    10,
                  ),
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: AppTheme.panelBg(isDark, isAmoled: isAmoled),
                      borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                      border: Border.all(
                        color: borderClr,
                        width: DmxTokens.borderThin,
                      ),
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final half = constraints.maxWidth / 2;
                        return Stack(
                          children: [
                            AnimatedBuilder(
                              animation: _tabSlide,
                              builder: (context, child) => Positioned(
                                left: _tabSlide.value * half,
                                top: 0,
                                bottom: 0,
                                width: half,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: AppTheme.surfaceColor(
                                      isDark,
                                      isAmoled: isAmoled,
                                      elevated: true,
                                    ),
                                    borderRadius: BorderRadius.circular(9),
                                    border: Border.all(
                                      color: accent.withValues(
                                        alpha: isDark ? 0.35 : 0.28,
                                      ),
                                      width: DmxTokens.borderThin,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: _tabButton(
                                    0,
                                    L10n.of(
                                      context,
                                      'browser_surfing_history',
                                    ),
                                    accent,
                                    isDark,
                                  ),
                                ),
                                Expanded(
                                  child: _tabButton(
                                    1,
                                    L10n.of(context, 'browser_downloads_tab'),
                                    accent,
                                    isDark,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),

                // Search bar
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    DmxTokens.sheetHorizontalPadding,
                    0,
                    DmxTokens.sheetHorizontalPadding,
                    10,
                  ),
                  child: AnimatedContainer(
                    duration: DmxTokens.animFast,
                    height: 42,
                    decoration: BoxDecoration(
                      color: AppTheme.panelBg(isDark, isAmoled: isAmoled),
                      borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                      border: Border.all(
                        color: _focusNode.hasFocus
                            ? accent.withValues(alpha: 0.65)
                            : borderClr,
                        width: _focusNode.hasFocus ? 1.2 : DmxTokens.borderThin,
                      ),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        Icon(
                          Icons.search_rounded,
                          size: 18,
                          color: _focusNode.hasFocus ? accent : textMuted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            focusNode: _focusNode,
                            style: TextStyle(
                              color: textPrimary,
                              fontSize: 13,
                              fontFamily: AppTheme.fontBody,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              filled: true,
                              fillColor: Colors.transparent,
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 10),
                              hintText: L10n.of(
                                context,
                                'browser_search_history_hint',
                              ),
                              hintStyle: TextStyle(
                                color: textMuted,
                                fontSize: DmxTokens.textSm,
                                fontFamily: AppTheme.fontBody,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                            ),
                          ),
                        ),
                        if (_searchController.text.isNotEmpty)
                          GestureDetector(
                            onTap: _searchController.clear,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              child: Icon(
                                Icons.cancel_rounded,
                                size: 17,
                                color: textMuted,
                              ),
                            ),
                          )
                        else
                          const SizedBox(width: 12),
                      ],
                    ),
                  ),
                ),

                Divider(
                  height: 1,
                  thickness: DmxTokens.borderThin,
                  color: borderClr,
                ),

                // Content list
                Expanded(
                  child: _selectedTab == 0
                      ? _buildSurfingList(
                          controller, isDark, isAmoled, settings)
                      : _buildDownloadsList(
                          controller,
                          isDark,
                          isAmoled,
                          downloadTasks,
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _tabButton(int index, String label, Color accent, bool isDark) {
    final isSelected = _selectedTab == index;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _switchTab(index),
      child: Center(
        child: Text(
          label.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: AppTheme.fontDisplay,
            color: isSelected ? accent : AppTheme.textSecondaryOf(isDark),
            fontSize: DmxTokens.textXs,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }

  Map<String, List<Map<String, dynamic>>> _groupHistoryByDay(
    List<Map<String, dynamic>> items,
  ) {
    final groups = <String, List<Map<String, dynamic>>>{};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final sevenDaysAgo = today.subtract(const Duration(days: 7));

    for (final item in items) {
      final visitedAtVal = item['visitedAt'];
      DateTime dt;
      if (visitedAtVal is num) {
        dt = DateTime.fromMillisecondsSinceEpoch(
          visitedAtVal.toInt(),
          isUtc: true,
        ).toLocal();
      } else if (visitedAtVal is String) {
        dt = (DateTime.tryParse(visitedAtVal) ?? now).toLocal();
      } else {
        dt = now;
      }

      final itemDate = DateTime(dt.year, dt.month, dt.day);
      String groupKey;
      if (itemDate == today) {
        groupKey = 'Today';
      } else if (itemDate == yesterday) {
        groupKey = 'Yesterday';
      } else if (itemDate.isAfter(sevenDaysAgo)) {
        groupKey = 'This Week';
      } else {
        groupKey = 'Older';
      }

      groups.putIfAbsent(groupKey, () => []).add(item);
    }
    return groups;
  }

  String _getGroupLabel(BuildContext context, String key) {
    final isRtl = L10n.isRtl(context);
    switch (key) {
      case 'Today':
        return isRtl ? 'اليوم' : 'Today';
      case 'Yesterday':
        return isRtl ? 'أمس' : 'Yesterday';
      case 'This Week':
        return isRtl ? 'هذا الأسبوع' : 'This Week';
      case 'Older':
        return isRtl ? 'أقدم' : 'Older';
      default:
        return key;
    }
  }

  Widget _buildSurfingList(
    ScrollController controller,
    bool isDark,
    bool isAmoled,
    SettingsProvider settings,
  ) {
    _attachPagination(controller);

    if (_isLoadingHistory) {
      return const SkeletonList(itemCount: 6, itemHeight: 64);
    }

    final filtered = _surfingHistory.where((item) {
      final title = (item['title'] as String? ?? '').toLowerCase();
      final url = (item['url'] as String? ?? '').toLowerCase();
      return title.contains(_searchQuery) || url.contains(_searchQuery);
    }).toList();

    if (filtered.isEmpty) return _emptyState(isDark, isSurfing: true);

    final grouped = _groupHistoryByDay(filtered);
    final listItems = <dynamic>[];
    const groupOrder = ['Today', 'Yesterday', 'This Week', 'Older'];
    for (final g in groupOrder) {
      if (grouped.containsKey(g) && grouped[g]!.isNotEmpty) {
        listItems.add(_DateGroupHeader(key: g, count: grouped[g]!.length));
        listItems.addAll(grouped[g]!);
      }
    }

    final trimmed = listItems.take(_visibleHistoryCount).toList();
    final hasMore = listItems.length > _visibleHistoryCount;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return ListView.builder(
      controller: controller,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        DmxTokens.sheetHorizontalPadding,
        8,
        DmxTokens.sheetHorizontalPadding,
        24,
      ),
      itemCount: trimmed.length + (hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == trimmed.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: TextButton.icon(
                onPressed: () {
                  setState(() => _visibleHistoryCount += _historyPageSize);
                },
                icon: const Icon(Icons.expand_more_rounded, size: 18),
                label: Text(
                  L10n.of(context, 'browser_load_more_history'),
                ),
              ),
            ),
          );
        }
        final item = trimmed[i];
        if (item is _DateGroupHeader) {
          return Padding(
            padding:
                const EdgeInsets.only(top: 14, bottom: 8, left: 2, right: 2),
            child: Row(
              children: [
                Text(
                  _getGroupLabel(context, item.key),
                  style: TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    color: accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: isDark ? 0.14 : 0.10),
                    borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
                  ),
                  child: Text(
                    '${item.count}',
                    style: AppTheme.dataStyle(
                      isDark: isDark,
                      size: DmxTokens.textXs,
                      weight: FontWeight.w700,
                      color: accent,
                    ),
                  ),
                ),
              ],
            ),
          );
        } else {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _surfingTile(
              context,
              item as Map<String, dynamic>,
              isDark,
              isAmoled,
              settings,
            ),
          );
        }
      },
    );
  }

  Widget _buildDownloadsList(
    ScrollController controller,
    bool isDark,
    bool isAmoled,
    List<DownloadTask> downloadTasks,
  ) {
    final filtered = downloadTasks.where((task) {
      final name = task.fileName.toLowerCase();
      final url = task.url.toLowerCase();
      return name.contains(_searchQuery) || url.contains(_searchQuery);
    }).toList();

    if (filtered.isEmpty) return _emptyState(isDark, isSurfing: false);

    return ListView.separated(
      controller: controller,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        DmxTokens.sheetHorizontalPadding,
        12,
        DmxTokens.sheetHorizontalPadding,
        24,
      ),
      itemCount: filtered.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, i) =>
          _taskTile(context, filtered[i], isDark, isAmoled),
    );
  }

  Widget _emptyState(bool isDark, {required bool isSurfing}) {
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textSecondary = AppTheme.textSecondaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final isRtl = L10n.isRtl(context);

    if (_searchQuery.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: textMuted.withValues(alpha: 0.12),
                ),
                child: Icon(
                  Icons.search_off_rounded,
                  size: 28,
                  color: textMuted,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '${L10n.of(context, 'browser_no_results_for')} "$_searchQuery"',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: AppTheme.fontDisplay,
                  color: textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _searchController.clear,
                icon: const Icon(Icons.clear_rounded, size: 16),
                label: Text(L10n.of(context, 'browser_clear_search')),
              ),
            ],
          ),
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: isDark ? 0.12 : 0.08),
                border: Border.all(
                  color: accent.withValues(alpha: 0.25),
                  width: DmxTokens.borderHairline,
                ),
              ),
              child: Icon(
                isSurfing
                    ? Icons.manage_history_rounded
                    : Icons.cloud_off_rounded,
                size: 32,
                color: accent,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              isSurfing
                  ? L10n.of(context, 'browser_no_history_found')
                  : L10n.of(context, 'browser_no_downloads_yet'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: AppTheme.fontDisplay,
                color: textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              isSurfing
                  ? L10n.of(context, 'browser_no_history_desc')
                  : L10n.of(context, 'browser_no_downloads_desc'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: AppTheme.fontBody,
                color: textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                backgroundColor: accent.withValues(alpha: isDark ? 0.16 : 0.12),
                foregroundColor: accent,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                  side: BorderSide(color: accent.withValues(alpha: 0.28)),
                ),
              ),
              icon: const Icon(Icons.language_rounded, size: 17),
              label: Text(
                isRtl ? 'تصفح الويب' : 'Explore Web',
                style: const TextStyle(
                  fontFamily: AppTheme.fontDisplay,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showClearHistoryConfirmation(SettingsProvider settings) async {
    final isDark = settings.isDarkMode;
    final isAmoled = settings.isAmoledMode;
    final red = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.sheetSurface(isDark, isAmoled: isAmoled),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DmxTokens.radius2xl),
          side: BorderSide(
            color: AppTheme.hairlineBorder(isDark, isAmoled: isAmoled),
          ),
        ),
        title: Text(
          L10n.of(context, 'browser_clear_history_title'),
          style: TextStyle(
            fontFamily: AppTheme.fontDisplay,
            color: red,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          L10n.of(context, 'browser_clear_history_desc'),
          style: TextStyle(
            fontFamily: AppTheme.fontBody,
            color: AppTheme.textSecondaryOf(isDark),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              HapticHelper.triggerHaptic(settings);
              Navigator.pop(context, false);
            },
            child: Text(
              L10n.of(context, 'browser_cancel_uppercase'),
              style: TextStyle(
                fontFamily: AppTheme.fontDisplay,
                color: AppTheme.textMutedOf(isDark),
              ),
            ),
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: red,
              side: BorderSide(color: red, width: 1.2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
              ),
            ),
            onPressed: () {
              HapticHelper.triggerHaptic(settings);
              Navigator.pop(context, true);
            },
            child: Text(
              L10n.of(context, 'browser_clear_btn'),
              style: const TextStyle(
                fontFamily: AppTheme.fontDisplay,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) _clearAllSurfingHistory();
  }

  Widget _surfingTile(
    BuildContext context,
    Map<String, dynamic> item,
    bool isDark,
    bool isAmoled,
    SettingsProvider settings,
  ) {
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final red = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final url = item['url'] as String? ?? '';
    final title = (item['title'] as String? ?? '').isNotEmpty
        ? item['title'] as String
        : url;
    final id = item['id'] as int? ?? 0;
    final faviconUrl = item['faviconUrl'] as String?;
    final timeStr = _formatTimestamp(item['visitedAt']);
    final host = _extractHost(url);
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);

    final tileWidget = Container(
      decoration: BoxDecoration(
        color:
            AppTheme.surfaceColor(isDark, isAmoled: isAmoled, elevated: true),
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        border: Border.all(
          color: AppTheme.hairlineBorder(isDark, isAmoled: isAmoled),
          width: DmxTokens.borderThin,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
          onTap: () {
            HapticHelper.triggerHaptic(settings);
            Navigator.pop(context, url);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: isDark ? 0.12 : 0.08),
                    borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
                  ),
                  child: faviconUrl != null && faviconUrl.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: CachedNetworkImage(
                            imageUrl: faviconUrl,
                            width: 18,
                            height: 18,
                            fit: BoxFit.contain,
                            placeholder: (context, url) => const SizedBox(
                              width: 18,
                              height: 18,
                            ),
                            errorWidget: (context, url, error) => Icon(
                              Icons.language_rounded,
                              color: accent,
                              size: 18,
                            ),
                            memCacheWidth: 36,
                          ),
                        )
                      : Icon(
                          Icons.language_rounded,
                          color: accent,
                          size: 18,
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          color: textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              host,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: AppTheme.fontBody,
                                color: accent,
                                fontSize: DmxTokens.textXs,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (timeStr.isNotEmpty) ...[
                            Text(
                              '  •  ',
                              style: TextStyle(
                                color: textMuted,
                                fontSize: DmxTokens.textXs,
                              ),
                            ),
                            Flexible(
                              child: Text(
                                timeStr,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: AppTheme.fontBody,
                                  color: textMuted,
                                  fontSize: DmxTokens.textXs,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                _TileAction(
                  icon: Icons.copy_rounded,
                  isDark: isDark,
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: url));
                    HapticHelper.triggerHaptic(settings);
                  },
                ),
                _TileAction(
                  icon: Icons.close_rounded,
                  isDark: isDark,
                  danger: true,
                  onTap: () {
                    HapticHelper.triggerHaptic(settings);
                    if (id > 0) _deleteHistoryItem(id);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (id <= 0) return tileWidget;

    return Dismissible(
      key: ValueKey('history_item_$id'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: AlignmentDirectional.centerEnd,
        padding: const EdgeInsetsDirectional.only(end: 16),
        decoration: BoxDecoration(
          color: red.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
          border: Border.all(
            color: red.withValues(alpha: 0.30),
            width: DmxTokens.borderThin,
          ),
        ),
        child: Icon(
          Icons.delete_outline_rounded,
          color: red,
          size: 20,
        ),
      ),
      onDismissed: (_) {
        HapticHelper.triggerHaptic(settings);
        _deleteHistoryItem(id);
      },
      child: tileWidget,
    );
  }

  Widget _taskTile(
    BuildContext context,
    DownloadTask t,
    bool isDark,
    bool isAmoled,
  ) {
    final color = _statusColor(t.status, isDark);
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);
    final sizeStr = formatBytes(t.fileSize);
    final timeStr = _formatDateTime(t.completedAt ?? t.createdAt);

    return Container(
      decoration: BoxDecoration(
        color:
            AppTheme.surfaceColor(isDark, isAmoled: isAmoled, elevated: true),
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        border: Border.all(
          color: AppTheme.hairlineBorder(isDark, isAmoled: isAmoled),
          width: DmxTokens.borderThin,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
          onTap: () {
            Clipboard.setData(ClipboardData(text: t.url));
            HapticHelper.triggerHaptic(context.read<SettingsProvider>());
            ThemedSnackbar.show(
              context,
              message:
                  '${L10n.of(context, 'browser_copied_url_for')} ${t.fileName}',
              color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
              icon: Icons.copy_rounded,
              isDarkMode: isDark,
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: isDark ? 0.14 : 0.10),
                    borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
                  ),
                  child: Icon(_statusIcon(t.status), color: color, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          color: textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Text(
                            sizeStr,
                            style: AppTheme.dataStyle(
                              isDark: isDark,
                              size: DmxTokens.textXs,
                              weight: FontWeight.w700,
                              color: color,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '• $timeStr',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: AppTheme.fontBody,
                                color: textMuted,
                                fontSize: DmxTokens.textXs,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: isDark ? 0.14 : 0.10),
                    borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
                    border: Border.all(
                      color: color.withValues(alpha: 0.28),
                      width: DmxTokens.borderThin,
                    ),
                  ),
                  child: Text(
                    _statusLabel(t.status, context),
                    style: TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      color: color,
                      fontSize: DmxTokens.textXs,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _statusIcon(DownloadStatus s) {
    switch (s) {
      case DownloadStatus.completed:
        return Icons.check_circle_outline;
      case DownloadStatus.downloading:
        return Icons.downloading_rounded;
      case DownloadStatus.paused:
        return Icons.pause_circle_outline;
      case DownloadStatus.failed:
        return Icons.error_outline;
      case DownloadStatus.queued:
        return Icons.schedule_rounded;
      case DownloadStatus.merging:
        return Icons.merge_type_rounded;
    }
  }

  Color _statusColor(DownloadStatus s, bool isDark) {
    switch (s) {
      case DownloadStatus.completed:
        return isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
      case DownloadStatus.downloading:
        return isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
      case DownloadStatus.paused:
        return isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
      case DownloadStatus.failed:
        return isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
      case DownloadStatus.queued:
        return isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
      case DownloadStatus.merging:
        return isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    }
  }

  String _statusLabel(DownloadStatus s, BuildContext context) {
    switch (s) {
      case DownloadStatus.completed:
        return L10n.of(context, 'browser_status_done');
      case DownloadStatus.downloading:
        return L10n.of(context, 'browser_status_active');
      case DownloadStatus.paused:
        return L10n.of(context, 'browser_status_paused');
      case DownloadStatus.failed:
        return L10n.of(context, 'browser_status_failed');
      case DownloadStatus.queued:
        return L10n.of(context, 'browser_status_queued');
      case DownloadStatus.merging:
        return 'Merging';
    }
  }
}

class _DateGroupHeader {
  final String key;
  final int count;

  const _DateGroupHeader({required this.key, required this.count});
}

class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isDark;
  final bool isAmoled;
  final bool danger;
  final VoidCallback onTap;

  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.isDark,
    required this.isAmoled,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger
        ? (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
        : AppTheme.textSecondaryOf(isDark);
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
          child: Container(
            width: 36,
            height: 36,
            margin: const EdgeInsetsDirectional.only(start: 4),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: danger
                  ? color.withValues(alpha: 0.12)
                  : AppTheme.panelBg(isDark, isAmoled: isAmoled),
              borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
              border: Border.all(
                color: danger
                    ? color.withValues(alpha: 0.30)
                    : AppTheme.hairlineBorder(isDark, isAmoled: isAmoled),
                width: DmxTokens.borderThin,
              ),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
        ),
      ),
    );
  }
}

class _TileAction extends StatelessWidget {
  final IconData icon;
  final bool isDark;
  final bool danger;
  final VoidCallback onTap;

  const _TileAction({
    required this.icon,
    required this.isDark,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger
        ? (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
        : AppTheme.textMutedOf(isDark);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: 16, color: color),
      ),
    );
  }
}
