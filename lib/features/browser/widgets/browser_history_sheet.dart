import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import 'dart:async';
import 'package:share_plus/share_plus.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../../core/utils/file_utils.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../settings/provider/settings_provider.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../../core/services/database_service.dart';

class BrowserHistorySheet extends StatefulWidget {
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

class _BrowserHistorySheetState extends State<BrowserHistorySheet> {
  int _selectedTab = 0; // 0: Surfing History, 1: Downloads
  List<Map<String, dynamic>> _surfingHistory = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _loadSurfingHistory();
    _searchController.addListener(() {
      if (_debounceTimer?.isActive ?? false) _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) {
          setState(() {
            _searchQuery = _searchController.text.toLowerCase().trim();
          });
        }
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  String _formatTimestamp(String? isoString) {
    if (isoString == null || isoString.isEmpty) return '';
    try {
      final dt = DateTime.parse(isoString);
      return _formatDateTime(dt);
    } catch (_) {
      return '';
    }
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _exportHistoryToJson() async {
    final settings = context.read<SettingsProvider>();
    runHaptic(settings);
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
      await SharePlus.instance.share(ShareParams(
        text: jsonStr,
        subject: _selectedTab == 0
            ? 'XDM Surfing History'
            : 'XDM Download History',
      ));
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
      final h = await db.loadBrowserHistory();
      if (!mounted) return;
      setState(() {
        _surfingHistory = h;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _surfingHistory = [];
      });
    }
  }

  Future<void> _deleteHistoryItem(String id) async {
    try {
      final db = context.read<DatabaseService>();
      await db.deleteBrowserHistory(id);
      _loadSurfingHistory();
    } catch (_) {}
  }

  Future<void> _clearAllSurfingHistory() async {
    try {
      final db = context.read<DatabaseService>();
      await db.clearBrowserHistory();
      _loadSurfingHistory();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    
    // Optimize: rebuild only when task keys or status changes, not on progress ticks
    context.select<DownloadProvider, String>(
      (p) => p.tasks.map((t) => '${t.id}_${t.status.name}').join(','),
    );
    final downloadTasks = context.read<DownloadProvider>().tasks;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
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
                color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                    .withValues(alpha: 0.95),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border(
                  top: BorderSide(
                    color: isDark
                        ? AppTheme.glassBorder
                        : AppTheme.lightGlassBorder,
                    width: 0.8,
                  ),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  children: [
                    // Header Area
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              _selectedTab == 0
                                  ? Icons.history
                                  : Icons.download,
                              color: accent,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _selectedTab == 0
                                  ? L10n.of(context, 'browser_history_title')
                                  : L10n.of(context, 'browser_download_history'),
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: accent,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.0,
                                  ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.ios_share,
                              color: accent,
                              size: 20,
                            ),
                            tooltip: L10n.of(context, 'browser_export_json'),
                            onPressed: _exportHistoryToJson,
                          ),
                          if (_selectedTab == 0 && _surfingHistory.isNotEmpty)
                            IconButton(
                              icon: Icon(
                                Icons.delete_sweep_outlined,
                                color: isDark
                                    ? AppTheme.neonRed
                                    : AppTheme.lightNeonRed,
                                size: 22,
                              ),
                              tooltip: L10n.of(context, 'browser_clear_history_btn'),
                              onPressed: () {
                                runHaptic(settings);
                                _showClearHistoryConfirmation(settings);
                              },
                            ),
                          TextButton(
                            onPressed: () {
                              runHaptic(settings);
                              Navigator.pop(context);
                            },
                            child: Text(L10n.of(context, 'browser_close_btn')),
                          ),
                        ],
                      ),
                    ),

                    // Custom Tabs Selector
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16.0,
                        vertical: 8.0,
                      ),
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color:
                              (isDark
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
                        child: Row(
                          children: [
                            Expanded(
                              child: _buildTabItem(
                                0,
                                L10n.of(context, 'browser_surfing_history'),
                                accent,
                                isDark,
                              ),
                            ),
                            Expanded(
                              child: _buildTabItem(
                                1,
                                L10n.of(context, 'browser_downloads_tab'),
                                accent,
                                isDark,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Search Bar
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16.0,
                        vertical: 4.0,
                      ),
                      child: Container(
                        height: 38,
                        decoration: BoxDecoration(
                          color:
                              (isDark
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
                        child: TextField(
                          controller: _searchController,
                          style: TextStyle(
                            color: isDark
                                ? AppTheme.textPrimary
                                : AppTheme.lightTextPrimary,
                            fontSize: 12,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 10,
                            ),
                            prefixIcon: Icon(
                              Icons.search,
                              size: 16,
                              color: isDark
                                  ? AppTheme.textSecondary
                                  : AppTheme.lightTextSecondary,
                            ),
                            suffixIcon: _searchController.text.isNotEmpty
                                ? GestureDetector(
                                    onTap: () {
                                      _searchController.clear();
                                    },
                                    child: Icon(
                                      Icons.close,
                                      size: 16,
                                      color: isDark
                                          ? AppTheme.textSecondary
                                          : AppTheme.lightTextSecondary,
                                    ),
                                  )
                                : null,
                            hintText: L10n.of(context, 'browser_search_history_hint'),
                            hintStyle: TextStyle(
                              color: isDark
                                  ? AppTheme.textMuted
                                  : AppTheme.lightTextMuted,
                              fontSize: 12,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            fillColor: Colors.transparent,
                          ),
                        ),
                      ),
                    ),

                    // Content Area
                    Expanded(
                      child: _selectedTab == 0
                          ? (() {
                              final filteredSurfing = _surfingHistory.where((
                                item,
                              ) {
                                final title = (item['title'] as String? ?? '')
                                    .toLowerCase();
                                final url = (item['url'] as String? ?? '')
                                    .toLowerCase();
                                return title.contains(_searchQuery) ||
                                    url.contains(_searchQuery);
                              }).toList();
                              return filteredSurfing.isEmpty
                                  ? _emptySurfingState(context, isDark)
                                  : ListView.separated(
                                      controller: controller,
                                      padding: const EdgeInsets.fromLTRB(
                                        12,
                                        4,
                                        12,
                                        24,
                                      ),
                                      itemCount: filteredSurfing.length,
                                      separatorBuilder: (context, index) =>
                                          const SizedBox(height: 6),
                                      itemBuilder: (context, i) {
                                        final item = filteredSurfing[i];
                                        return _surfingTile(
                                          context,
                                          item,
                                          isDark,
                                          settings,
                                        );
                                      },
                                    );
                            })()
                          : (() {
                              final filteredDownloads = downloadTasks.where((
                                task,
                              ) {
                                final name = task.fileName.toLowerCase();
                                final url = task.url.toLowerCase();
                                return name.contains(_searchQuery) ||
                                    url.contains(_searchQuery);
                              }).toList();
                              return filteredDownloads.isEmpty
                                  ? _emptyDownloadsState(context, isDark)
                                  : ListView.separated(
                                      controller: controller,
                                      padding: const EdgeInsets.fromLTRB(
                                        12,
                                        4,
                                        12,
                                        24,
                                      ),
                                      itemCount: filteredDownloads.length,
                                      separatorBuilder: (context, index) =>
                                          const SizedBox(height: 6),
                                      itemBuilder: (context, i) {
                                        final task = filteredDownloads[i];
                                        return _taskTile(context, task, isDark);
                                      },
                                    );
                            })(),
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

  Widget _buildTabItem(int index, String label, Color accent, bool isDark) {
    final isSelected = _selectedTab == index;
    return GestureDetector(
      onTap: () {
        runHaptic(context.read<SettingsProvider>());
        setState(() {
          _selectedTab = index;
        });
      },
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(
                  alpha: 0.8,
                )
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: isSelected
              ? Border.all(
                  color: isDark
                      ? AppTheme.glassBorder
                      : AppTheme.lightGlassBorder,
                  width: 0.8,
                )
              : null,
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: isSelected
                ? accent
                : (isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary),
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }

  Widget _emptySurfingState(BuildContext context, bool isDark) {
    if (_searchQuery.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.search_off_rounded,
                size: 56,
                color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
              ),
              const SizedBox(height: 14),
              Text(
                '${L10n.of(context, 'browser_no_results_for')} "$_searchQuery"',
                style: TextStyle(
                  color: isDark
                      ? AppTheme.textPrimary
                      : AppTheme.lightTextPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () => _searchController.clear(),
                icon: const Icon(Icons.clear, size: 16),
                label: Text(L10n.of(context, 'browser_clear_search')),
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.history,
              size: 56,
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
            ),
            const SizedBox(height: 14),
            Text(
              L10n.of(context, 'browser_no_history_found'),
              style: TextStyle(
                color: isDark
                    ? AppTheme.textPrimary
                    : AppTheme.lightTextPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              L10n.of(context, 'browser_no_history_desc'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyDownloadsState(BuildContext context, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 56,
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
            ),
            const SizedBox(height: 14),
            Text(
              L10n.of(context, 'browser_no_downloads_yet'),
              style: TextStyle(
                color: isDark
                    ? AppTheme.textPrimary
                    : AppTheme.lightTextPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              L10n.of(context, 'browser_no_downloads_desc'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showClearHistoryConfirmation(SettingsProvider settings) async {
    final isDark = settings.isDarkMode;

    showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
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
            L10n.of(context, 'browser_clear_history_content'),
            style: TextStyle(
              color: isDark
                  ? AppTheme.textSecondary
                  : AppTheme.lightTextSecondary,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                runHaptic(settings);
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
                runHaptic(settings);
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
        );
      },
    ).then((confirmed) {
      if (confirmed == true) {
        _clearAllSurfingHistory();
      }
    });
  }

  Widget _surfingTile(
    BuildContext context,
    Map<String, dynamic> item,
    bool isDark,
    SettingsProvider settings,
  ) {
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final url = item['url'] as String? ?? '';
    final title = item['title'] as String? ?? url;
    final id = item['id'] as String? ?? '';
    final visitedAt = item['visitedAt'] as String? ?? '';
    final timeStr = _formatTimestamp(visitedAt);

    return Container(
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.glassBg : AppTheme.lightGlassBg).withValues(
          alpha: 0.4,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
          width: 0.6,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            runHaptic(settings);
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
                  child: Icon(Icons.language, color: accent, size: 18),
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
                          color: isDark
                              ? AppTheme.textPrimary
                              : AppTheme.lightTextPrimary,
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
                              ? AppTheme.textMuted
                              : AppTheme.lightTextMuted,
                          fontSize: 10,
                        ),
                      ),
                      if (timeStr.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          timeStr,
                          style: TextStyle(
                            color: isDark
                                ? AppTheme.textMuted
                                : AppTheme.lightTextMuted,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.copy,
                    size: 16,
                    color: isDark
                        ? AppTheme.textSecondary
                        : AppTheme.lightTextSecondary,
                  ),
                  tooltip: 'Copy URL',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: url));
                    runHaptic(settings);
                  },
                ),
                IconButton(
                  icon: Icon(
                    Icons.close,
                    size: 16,
                    color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                  ),
                  tooltip: 'Remove',
                  onPressed: () {
                    runHaptic(settings);
                    if (id.isNotEmpty) {
                      _deleteHistoryItem(id);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _taskTile(BuildContext context, DownloadTask t, bool isDark) {
    final color = _statusColor(t.status, isDark);
    final sizeStr = formatBytes(t.fileSize);
    final timeStr = _formatDateTime(t.completedAt ?? t.createdAt);

    return Container(
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.glassBg : AppTheme.lightGlassBg).withValues(
          alpha: 0.4,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
          width: 0.6,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            Clipboard.setData(ClipboardData(text: t.url));
            runHaptic(context.read<SettingsProvider>());
            final isDark = context.read<SettingsProvider>().isDarkMode;
            ThemedSnackbar.show(
              context,
              message: '${L10n.of(context, 'browser_copied_url_for')} ${t.fileName}',
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
                          color: isDark
                              ? AppTheme.textPrimary
                              : AppTheme.lightTextPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            sizeStr,
                            style: TextStyle(
                              color: color,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '•  $timeStr',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isDark
                                    ? AppTheme.textMuted
                                    : AppTheme.lightTextMuted,
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
                  ),
                  child: Text(
                    _statusLabel(t.status, context),
                    style: TextStyle(
                      color: color,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.6,
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
        return Icons.downloading;
      case DownloadStatus.paused:
        return Icons.pause_circle_outline;
      case DownloadStatus.failed:
        return Icons.error_outline;
      case DownloadStatus.queued:
        return Icons.schedule;
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
    }
  }
}
