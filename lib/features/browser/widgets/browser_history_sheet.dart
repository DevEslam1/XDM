import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/database_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';

class BrowserHistorySheet extends StatefulWidget {
  static final _log = Logger('BrowserHistorySheet');
  const BrowserHistorySheet({super.key});

  static Future<String?> show(BuildContext context) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
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
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _debounceTimer;
  final FocusNode _focusNode = FocusNode();
  late final AnimationController _tabSlide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
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
          // FIX: Re-query the database with the new search term so results
          // include entries beyond the initial 200-item load window.
          _loadSurfingHistory();
        }
      });
    });
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
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
    // FIX(5): visited_at is now INTEGER ms-epoch; keep parsing legacy ISO
    // strings for robustness.
    if (value is num) {
      final ms = value.toInt();
      // FIX: Guard against negative or zero timestamps from corrupt
      // migrations — showing "1970-01-01" is worse than showing nothing.
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
      final jsonStr = const JsonEncoder.withIndent('  ').convert(exportData);
      final tempDir = await getTemporaryDirectory();
      final name = _selectedTab == 0
          ? 'xdm_surfing_history.json'
          : 'xdm_download_history.json';
      final file = File(p.join(tempDir.path, name));
      await file.writeAsString(jsonStr);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: _selectedTab == 0
              ? 'XDM Surfing History'
              : 'XDM Download History',
        ),
      );
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
      // FIX: Pass the search query to the database so it can search across
      // ALL history entries, not just the pre-loaded 200-item window.
      final h = await db.loadBrowserHistory(
        max: 500,
        searchQuery: _searchQuery.isNotEmpty ? _searchQuery : null,
      );
      if (!mounted) return;
      setState(() => _surfingHistory = h);
    } catch (e) {
      BrowserHistorySheet._log.warning('[HistorySheet] Error: $e');
      if (!mounted) return;
      setState(() => _surfingHistory = []);
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
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final muted = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    final downloadTasks =
        context.select<DownloadProvider, List<DownloadTask>>((p) => p.tasks);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (context, controller) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: DmxBackdropFilter(
            sigmaX: 15,
            sigmaY: 15,
            child: Container(
              decoration: BoxDecoration(
                color: (isDark
                        ? (settings.isAmoledMode
                            ? AppTheme.amoledSurface
                            : AppTheme.surface)
                        : AppTheme.lightSurface)
                    .withValues(alpha: settings.isAmoledMode ? 1.0 : 0.95),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border(
                  top: BorderSide(
                    color: isDark
                        ? (settings.isAmoledMode
                            ? AppTheme.amoledBorder
                            : AppTheme.glassBorder)
                        : AppTheme.lightGlassBorder,
                    width: 0.8,
                  ),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  children: [
                    // Grab handle
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(top: 12, bottom: 10),
                        decoration: BoxDecoration(
                          color: muted.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    // Header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 2, 12, 6),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(13),
                              border: Border.all(
                                color: accent.withValues(alpha: 0.3),
                              ),
                            ),
                            child: Icon(
                              _selectedTab == 0
                                  ? Icons.history_rounded
                                  : Icons.download_rounded,
                              color: accent,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _selectedTab == 0
                                  ? L10n.of(context, 'browser_history_title')
                                  : L10n.of(
                                      context,
                                      'browser_download_history',
                                    ),
                              style: TextStyle(
                                fontFamily: 'Space Grotesk',
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                                letterSpacing: 1,
                                color: textClr,
                              ),
                            ),
                          ),
                          _HeaderAction(
                            icon: Icons.ios_share_rounded,
                            tooltip: L10n.of(context, 'browser_export_json'),
                            isDark: isDark,
                            onTap: _exportHistoryToJson,
                          ),
                          if (_selectedTab == 0 && _surfingHistory.isNotEmpty)
                            _HeaderAction(
                              icon: Icons.delete_sweep_outlined,
                              tooltip: L10n.of(
                                context,
                                'browser_clear_history_btn',
                              ),
                              isDark: isDark,
                              danger: true,
                              onTap: () {
                                HapticHelper.triggerHaptic(settings);
                                _showClearHistoryConfirmation(settings);
                              },
                            ),
                          _HeaderAction(
                            icon: Icons.close_rounded,
                            tooltip: L10n.of(context, 'browser_close_btn'),
                            isDark: isDark,
                            onTap: () {
                              HapticHelper.triggerHaptic(settings);
                              Navigator.pop(context);
                            },
                          ),
                        ],
                      ),
                    ),
                    // Sliding tab selector
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Container(
                        height: 42,
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: (isDark
                                  ? AppTheme.background
                                  : AppTheme.lightBackground)
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark
                                ? AppTheme.glassBorder
                                : AppTheme.lightGlassBorder,
                            width: 0.8,
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
                                    top: 3,
                                    bottom: 3,
                                    width: half - 6,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: accent.withValues(alpha: 0.14),
                                        borderRadius: BorderRadius.circular(9),
                                        border: Border.all(
                                          color: accent.withValues(alpha: 0.4),
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
                                        L10n.of(
                                          context,
                                          'browser_downloads_tab',
                                        ),
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
                    // Search field
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        height: 42,
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF0F0F16)
                              : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(21),
                          border: Border.all(
                            color: _focusNode.hasFocus
                                ? accent.withValues(alpha: 0.6)
                                : (isDark
                                    ? const Color(0x15FFFFFF)
                                    : const Color(0x0D000000)),
                            width: _focusNode.hasFocus ? 1.5 : 1.0,
                          ),
                          boxShadow: _focusNode.hasFocus &&
                                  isDark &&
                                  settings.enableGlow
                              ? [
                                  BoxShadow(
                                    color: accent.withValues(alpha: 0.25),
                                    blurRadius: 10,
                                    spreadRadius: 0.5,
                                  ),
                                ]
                              : null,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const SizedBox(width: 14),
                            Icon(
                              Icons.search_rounded,
                              size: 18,
                              color: _focusNode.hasFocus ? accent : muted,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                focusNode: _focusNode,
                                style: TextStyle(
                                  color: textClr,
                                  fontSize: 13,
                                  fontFamily: 'Inter',
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  filled: true,
                                  fillColor: Colors.transparent,
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  hintText: L10n.of(
                                    context,
                                    'browser_search_history_hint',
                                  ),
                                  hintStyle:
                                      TextStyle(color: muted, fontSize: 12),
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                ),
                              ),
                            ),
                            if (_searchController.text.isNotEmpty) ...[
                              GestureDetector(
                                onTap: _searchController.clear,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                  child: Icon(
                                    Icons.close_rounded,
                                    size: 17,
                                    color: muted,
                                  ),
                                ),
                              ),
                            ] else
                              const SizedBox(width: 14),
                          ],
                        ),
                      ),
                    ),
                    // Content
                    Expanded(
                      child: _selectedTab == 0
                          ? _buildSurfingList(controller, isDark, settings)
                          : _buildDownloadsList(
                              controller,
                              isDark,
                              downloadTasks,
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
  }

  Widget _tabButton(int index, String label, Color accent, bool isDark) {
    final isSelected = _selectedTab == index;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _switchTab(index),
      child: Center(
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontFamily: 'Space Grotesk',
            color: isSelected
                ? accent
                : (isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary),
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }

  Map<String, List<Map<String, dynamic>>> _groupHistoryByDay(
      List<Map<String, dynamic>> items) {
    final groups = <String, List<Map<String, dynamic>>>{};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final sevenDaysAgo = today.subtract(const Duration(days: 7));

    for (final item in items) {
      final visitedAtVal = item['visitedAt'];
      DateTime dt;
      if (visitedAtVal is num) {
        dt = DateTime.fromMillisecondsSinceEpoch(visitedAtVal.toInt(),
                isUtc: true)
            .toLocal();
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
    SettingsProvider settings,
  ) {
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
        listItems.add(g);
        listItems.addAll(grouped[g]!);
      }
    }

    return ListView.builder(
      controller: controller,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
      itemCount: listItems.length,
      itemBuilder: (context, i) {
        final item = listItems[i];
        if (item is String) {
          return Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 6, left: 4),
            child: Text(
              _getGroupLabel(context, item),
              style: TextStyle(
                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                fontFamily: 'Space Grotesk',
              ),
            ),
          );
        } else {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: _surfingTile(
              context,
              item as Map<String, dynamic>,
              isDark,
              settings,
              i,
            ),
          );
        }
      },
    );
  }

  Widget _buildDownloadsList(
    ScrollController controller,
    bool isDark,
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
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
      itemCount: filtered.length,
      separatorBuilder: (context, index) => const SizedBox(height: 6),
      itemBuilder: (context, i) => _taskTile(context, filtered[i], isDark, i),
    );
  }

  Widget _emptyState(bool isDark, {required bool isSurfing}) {
    final muted = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    if (_searchQuery.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off_rounded, size: 48, color: muted),
            const SizedBox(height: 12),
            Text(
              '${L10n.of(context, 'browser_no_results_for')} "$_searchQuery"',
              style: TextStyle(
                color: textClr,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: _searchController.clear,
              icon: const Icon(Icons.clear, size: 15),
              label: Text(L10n.of(context, 'browser_clear_search')),
            ),
          ],
        ),
      );
    }

    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final isRtl = L10n.isRtl(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    accent.withValues(alpha: 0.2),
                    accent.withValues(alpha: 0.05),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.15),
                    blurRadius: 16,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Center(
                child: Icon(
                  isSurfing
                      ? Icons.manage_history_rounded
                      : Icons.cloud_off_rounded,
                  size: 44,
                  color: accent,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              isSurfing
                  ? L10n.of(context, 'browser_no_history_found')
                  : L10n.of(context, 'browser_no_downloads_yet'),
              style: TextStyle(
                color: textClr,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              isSurfing
                  ? L10n.of(context, 'browser_no_history_desc')
                  : L10n.of(context, 'browser_no_downloads_desc'),
              textAlign: TextAlign.center,
              style: TextStyle(color: secClr, fontSize: 12),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: accent.withValues(alpha: 0.15),
                foregroundColor: accent,
                elevation: 0,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: accent.withValues(alpha: 0.3)),
                ),
              ),
              icon: const Icon(Icons.language_rounded, size: 16),
              label: Text(
                isRtl ? 'تصفح الويب' : 'Explore Web',
                style: const TextStyle(fontWeight: FontWeight.bold),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? AppTheme.surface : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
          ),
        ),
        title: Text(
          L10n.of(context, 'browser_clear_history_title'),
          style: TextStyle(
            color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          L10n.of(context, 'browser_clear_history_desc'),
          style: TextStyle(
            color:
                isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
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
                color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
              ),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark
                  ? AppTheme.neonRed.withValues(alpha: 0.2)
                  : AppTheme.lightNeonRed.withValues(alpha: 0.1),
              side: BorderSide(
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () {
              HapticHelper.triggerHaptic(settings);
              Navigator.pop(context, true);
            },
            child: Text(
              L10n.of(context, 'browser_clear_btn'),
              style: TextStyle(
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                fontWeight: FontWeight.bold,
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
    SettingsProvider settings,
    int index,
  ) {
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final url = item['url'] as String? ?? '';
    final title = item['title'] as String? ?? url;
    final id = item['id'] as int? ?? 0;
    final faviconUrl = item['faviconUrl'] as String?;
    final timeStr = _formatTimestamp(item['visitedAt']);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: (260 + index * 30).clamp(260, 600)),
      curve: Curves.easeOut,
      builder: (_, t, child) => Opacity(opacity: t, child: child),
      child: Container(
        decoration: BoxDecoration(
          color: isDark
              ? (settings.isAmoledMode
                  ? AppTheme.amoledCardBg
                  : AppTheme.cardBg)
              : AppTheme.lightCardBg,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: isDark
                ? (settings.isAmoledMode
                    ? AppTheme.amoledBorder
                    : AppTheme.border.withValues(alpha: 0.5))
                : AppTheme.lightBorder,
            width: 0.8,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(13),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: BorderRadius.circular(13),
            onTap: () {
              HapticHelper.triggerHaptic(settings);
              Navigator.pop(context, url);
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: faviconUrl != null && faviconUrl.isNotEmpty
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: CachedNetworkImage(
                              imageUrl: faviconUrl,
                              width: 16,
                              height: 16,
                              fit: BoxFit.contain,
                              placeholder: (context, url) => const SizedBox(
                                width: 16,
                                height: 16,
                              ),
                              errorWidget: (context, url, error) => Icon(
                                Icons.language_rounded,
                                color: accent,
                                size: 16,
                              ),
                              memCacheWidth: 32,
                            ),
                          )
                        : Icon(
                            Icons.language_rounded,
                            color: accent,
                            size: 16,
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
                            color: textClr,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isDark
                                ? accent.withValues(alpha: 0.85)
                                : AppTheme.lightNeonBlue,
                            fontSize: 10.5,
                          ),
                        ),
                        if (timeStr.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            timeStr,
                            style: TextStyle(
                              color: isDark ? Colors.white54 : Colors.black54,
                              fontSize: 9.5,
                            ),
                          ),
                        ],
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
      ),
    );
  }

  Widget _taskTile(
    BuildContext context,
    DownloadTask t,
    bool isDark,
    int index,
  ) {
    final color = _statusColor(t.status, isDark);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final sizeStr = formatBytes(t.fileSize);
    final timeStr = _formatDateTime(t.completedAt ?? t.createdAt);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: (260 + index * 30).clamp(260, 600)),
      curve: Curves.easeOut,
      builder: (_, o, child) => Opacity(opacity: o, child: child),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? AppTheme.cardBg : AppTheme.lightCardBg,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: isDark
                ? AppTheme.border.withValues(alpha: 0.5)
                : AppTheme.lightBorder,
            width: 0.8,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(13),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: BorderRadius.circular(13),
            onTap: () {
              Clipboard.setData(ClipboardData(text: t.url));
              HapticHelper.triggerHaptic(context.read<SettingsProvider>());
              ThemedSnackbar.show(
                context,
                message:
                    '${L10n.of(context, 'browser_copied_url_for')} ${t.fileName}',
                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                icon: Icons.copy,
                isDarkMode: isDark,
              );
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(_statusIcon(t.status), color: color, size: 16),
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
                            color: textClr,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Text(
                              sizeStr,
                              style: TextStyle(
                                color: color,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Space Grotesk',
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '• $timeStr',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color:
                                      isDark ? Colors.white54 : Colors.black54,
                                  fontSize: 10,
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
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: color.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      _statusLabel(t.status, context),
                      style: TextStyle(
                        color: color,
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        fontFamily: 'Space Grotesk',
                      ),
                    ),
                  ),
                ],
              ),
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

class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isDark;
  final bool danger;
  final VoidCallback onTap;

  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.isDark,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger
        ? (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
        : (isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary);
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            width: 34,
            height: 34,
            margin: const EdgeInsetsDirectional.only(start: 4),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: (danger
                      ? color
                      : (isDark ? AppTheme.cardBg : AppTheme.lightCardBg))
                  .withValues(alpha: danger ? 0.12 : 0.5),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: danger
                    ? color.withValues(alpha: 0.35)
                    : (isDark ? AppTheme.border : AppTheme.lightBorder),
                width: 0.8,
              ),
            ),
            child: Icon(icon, size: 17, color: color),
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
        : (isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary);
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 8),
        child: Icon(icon, size: 15, color: color),
      ),
    );
  }
}
