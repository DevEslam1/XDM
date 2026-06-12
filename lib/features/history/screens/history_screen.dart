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

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DownloadProvider>(context);
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;

    // Filter for completed or failed tasks matching search
    final historyTasks = provider.tasks.where((task) {
      final isSeeding = task.status == DownloadStatus.completed && task.isTorrent && task.seedingEnabled;
      final isHistory =
          (task.status == DownloadStatus.completed ||
          task.status == DownloadStatus.failed) && !isSeeding;
      if (!isHistory) return false;

      if (_searchQuery.trim().isEmpty) return true;

      return task.fileName.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          task.url.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: ClipRect(
            child: DmxBackdropFilter(
              sigmaX: 12,
              sigmaY: 12,
              child: Container(
                color: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.5),
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
                tooltip: isRtl ? 'مسح كل السجل' : 'CLEAR ALL HISTORY',
                onPressed: () => _showClearHistoryConfirmation(
                  context,
                  provider,
                  historyTasks,
                  settings,
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
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: DmxBackdropFilter(
                      sigmaX: 8,
                      sigmaY: 8,
                      child: Container(
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF0F0F16) : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isDark ? const Color(0x15FFFFFF) : const Color(0x0D000000),
                            width: 0.8,
                          ),
                        ),
                        child: TextField(
                          controller: _searchController,
                          style: TextStyle(
                            color: textClr,
                            fontSize: 14,
                          ),
                          decoration: InputDecoration(
                            hintText: isRtl ? 'بحث في السجل...' : 'SEARCH HISTORY SIGNALS...',
                            hintStyle: TextStyle(
                              color: mutedClr,
                              fontSize: 12,
                            ),
                            prefixIcon: Icon(
                              Icons.search,
                              color: secClr,
                              size: 18,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 14,
                            ),
                          ),
                          onChanged: (value) {
                            setState(() {
                              _searchQuery = value;
                            });
                          },
                        ),
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
                        isRtl ? 'عمليات النقل المكتملة' : 'RESOLVED TRANSMISSIONS',
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: secClr,
                          fontSize: 9,
                          letterSpacing: 1.0,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${historyTasks.length} ${isRtl ? 'سجلات' : 'RECORDS'}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
                      ? _buildEmptyState(context, isDark, isRtl)
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          physics: const BouncingScrollPhysics(),
                          itemCount: historyTasks.length,
                          itemBuilder: (context, index) {
                            return DownloadCard(task: historyTasks[index]);
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, bool isDark, bool isRtl) {
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final glassBg = isDark ? AppTheme.glassBg : AppTheme.lightGlassBg;
    final glassBorder = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;

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
              Icons.history_toggle_off_outlined,
              size: 40,
              color: mutedClr,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            isRtl ? 'لم يتم العثور على إشارات مكتملة' : 'NO COMPLETED SIGNALS FOUND',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: secClr,
              letterSpacing: 1.0,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isRtl ? 'سيتم تصنيف السجلات المكتملة هنا.' : 'Finished logs will be cataloged here.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: mutedClr,
              fontSize: 11,
            ),
          ),
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
    final glassBorder = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

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
              isRtl ? 'مسح سجل التاريخ' : 'CLEAR HISTORY LOGS',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: redClr,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
              ),
            ),
            content: Text(
              isRtl
                  ? 'هل أنت متأكد من حذف جميع سجلات التاريخ البالغ عددها ${tasksToClear.length}؟'
                  : 'Are you sure you want to delete all ${tasksToClear.length} completed history records?',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: secClr),
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
                  isRtl ? 'مسح الكل' : 'CLEAR ALL',
                  style: TextStyle(
                    color: redClr,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: () async {
                  for (final task in tasksToClear) {
                    await provider.deleteTask(task.id);
                  }
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
