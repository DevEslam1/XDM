import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
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

  @override
  void initState() {
    super.initState();
    _loadSurfingHistory();
  }

  void _loadSurfingHistory() {
    try {
      final db = context.read<DatabaseService>();
      setState(() {
        _surfingHistory = db.loadBrowserHistory();
      });
    } catch (_) {
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
    final downloadProvider = context.watch<DownloadProvider>();
    final downloadTasks = downloadProvider.tasks;

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
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
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
                              _selectedTab == 0 ? Icons.history : Icons.download,
                              color: accent,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _selectedTab == 0 ? 'BROWSER HISTORY' : 'DOWNLOAD HISTORY',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
                                    color: accent,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.0,
                                  ),
                            ),
                          ),
                          if (_selectedTab == 0 && _surfingHistory.isNotEmpty)
                            IconButton(
                              icon: Icon(
                                Icons.delete_sweep_outlined,
                                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                                size: 22,
                              ),
                              tooltip: 'Clear history',
                              onPressed: () {
                                runHaptic(settings);
                                _clearAllSurfingHistory();
                              },
                            ),
                          TextButton(
                            onPressed: () {
                              runHaptic(settings);
                              Navigator.pop(context);
                            },
                            child: const Text('CLOSE'),
                          ),
                        ],
                      ),
                    ),

                    // Custom Tabs Selector
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: (isDark ? AppTheme.background : AppTheme.lightBackground).withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: _buildTabItem(0, 'Surfing History', accent, isDark),
                            ),
                            Expanded(
                              child: _buildTabItem(1, 'Downloads', accent, isDark),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Content Area
                    Expanded(
                      child: _selectedTab == 0
                          ? _surfingHistory.isEmpty
                              ? _emptySurfingState(context, isDark)
                              : ListView.separated(
                                  controller: controller,
                                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                                  itemCount: _surfingHistory.length,
                                  separatorBuilder: (context, index) => const SizedBox(height: 6),
                                  itemBuilder: (context, i) {
                                    final item = _surfingHistory[i];
                                    return _surfingTile(context, item, isDark, settings);
                                  },
                                )
                          : downloadTasks.isEmpty
                              ? _emptyDownloadsState(context, isDark)
                              : ListView.separated(
                                  controller: controller,
                                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                                  itemCount: downloadTasks.length,
                                  separatorBuilder: (context, index) => const SizedBox(height: 6),
                                  itemBuilder: (context, i) {
                                    final task = downloadTasks[i];
                                    return _taskTile(context, task, isDark);
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
              ? (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.8)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: isSelected
              ? Border.all(
                  color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                  width: 0.8,
                )
              : null,
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: isSelected
                ? accent
                : (isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary),
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }

  Widget _emptySurfingState(BuildContext context, bool isDark) {
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
              'No history found',
              style: TextStyle(
                color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Websites you visit will be listed here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
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
              'No downloads yet',
              style: TextStyle(
                color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Files you download from the browser will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _surfingTile(
      BuildContext context, Map<String, dynamic> item, bool isDark, SettingsProvider settings) {
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final url = item['url'] as String? ?? '';
    final title = item['title'] as String? ?? url;
    final id = item['id'] as String? ?? '';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          runHaptic(settings);
          Navigator.pop(context, url);
        },
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: (isDark ? AppTheme.glassBg : AppTheme.lightGlassBg).withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
              width: 0.6,
            ),
          ),
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
                        color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
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
                        color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.copy,
                  size: 16,
                  color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
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
    );
  }

  Widget _taskTile(BuildContext context, DownloadTask t, bool isDark) {
    final color = _statusColor(t.status, isDark);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          Clipboard.setData(ClipboardData(text: t.url));
          runHaptic(context.read<SettingsProvider>());
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Copied URL for: ${t.fileName}'),
              duration: const Duration(seconds: 2),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: (isDark ? AppTheme.glassBg : AppTheme.lightGlassBg).withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
              width: 0.6,
            ),
          ),
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
                        color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      t.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _statusLabel(t.status),
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

  String _statusLabel(DownloadStatus s) {
    switch (s) {
      case DownloadStatus.completed:
        return 'DONE';
      case DownloadStatus.downloading:
        return 'ACTIVE';
      case DownloadStatus.paused:
        return 'PAUSED';
      case DownloadStatus.failed:
        return 'FAILED';
      case DownloadStatus.queued:
        return 'QUEUED';
    }
  }
}
