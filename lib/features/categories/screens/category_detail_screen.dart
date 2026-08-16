import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/widgets/download_card.dart';
import '../../settings/provider/settings_provider.dart';

/// Displays a drill-down view for a single download category.
/// Shows: total size, file count, pie chart, list of completed downloads.
class CategoryDetailScreen extends StatelessWidget {
  final String categoryName;
  final Color categoryColor;
  final IconData categoryIcon;

  const CategoryDetailScreen({
    super.key,
    required this.categoryName,
    required this.categoryColor,
    required this.categoryIcon,
  });

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    // Get all tasks in this category that are completed/failed
    final tasks = context.select<DownloadProvider, List<DownloadTask>>(
      (p) => p.tasks,
    );
    final categoryTasks = tasks
        .where((t) =>
            t.category == categoryName &&
            (t.status == DownloadStatus.completed ||
                t.status == DownloadStatus.failed))
        .toList();

    final totalSizeBytes =
        categoryTasks.fold<double>(0, (sum, t) => sum + t.fileSize.toDouble());
    final totalSizeMb = totalSizeBytes / (1024 * 1024);
    final fileCount = categoryTasks.length;

    final String totalSizeText;
    if (totalSizeMb >= 1024) {
      totalSizeText = '${(totalSizeMb / 1024).toStringAsFixed(2)} GB';
    } else {
      totalSizeText = '${totalSizeMb.toStringAsFixed(1)} MB';
    }

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          elevation: 0,
          flexibleSpace: ClipRect(
            child: DmxBackdropFilter(
              sigmaX: 12,
              sigmaY: 12,
              child: Container(
                color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                    .withValues(alpha: 0.5),
              ),
            ),
          ),
          leading: IconButton(
            icon: Icon(
              isRtl ? Icons.arrow_forward_rounded : Icons.arrow_back_rounded,
              color: textClr,
            ),
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: categoryColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(categoryIcon, color: categoryColor, size: 18),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  categoryName,
                  style: TextStyle(
                    color: textClr,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    letterSpacing: 0.5,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        body: Directionality(
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: SafeArea(
            child: Column(
              children: [
                // Summary header card
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: _SummaryCard(
                    categoryName: categoryName,
                    categoryColor: categoryColor,
                    fileCount: fileCount,
                    totalSizeText: totalSizeText,
                    isDark: isDark,
                    textClr: textClr,
                    secClr: secClr,
                    mutedClr: mutedClr,
                    tasks: categoryTasks,
                  ),
                ),

                // File list header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    children: [
                      Icon(Icons.list_rounded, size: 14, color: categoryColor),
                      const SizedBox(width: 6),
                      Text(
                        isRtl ? 'ملفات ($fileCount)' : 'Files ($fileCount)',
                        style: TextStyle(
                          color: mutedClr,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // Downloads list
                Expanded(
                  child: categoryTasks.isEmpty
                      ? DmxEmptyState(
                          icon: categoryIcon,
                          title: categoryName,
                          subtitle: isRtl
                              ? 'لا توجد ملفات في هذه الفئة'
                              : 'No files in this category',
                          accentColor: categoryColor,
                        )
                      : Builder(
                          builder: (context) {
                            final isWide =
                                MediaQuery.sizeOf(context).width >= 600;
                            if (isWide) {
                              return GridView.builder(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 4,
                                ),
                                physics: const BouncingScrollPhysics(),
                                gridDelegate:
                                    const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 540,
                                  mainAxisExtent: 175,
                                  crossAxisSpacing: 14,
                                  mainAxisSpacing: 12,
                                ),
                                itemCount: categoryTasks.length,
                                itemBuilder: (context, index) {
                                  final task = categoryTasks[index];
                                  return DownloadCard(
                                    key: ValueKey(task.id),
                                    task: task,
                                    compact: true,
                                  );
                                },
                              );
                            }
                            return ListView.separated(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              physics: const BouncingScrollPhysics(),
                              itemCount: categoryTasks.length,
                              separatorBuilder: (context, index) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                final task = categoryTasks[index];
                                return DownloadCard(
                                  key: ValueKey(task.id),
                                  task: task,
                                  compact: true,
                                );
                              },
                            );
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
}

// Summary card with stats + pie chart
class _SummaryCard extends StatelessWidget {
  final String categoryName;
  final Color categoryColor;
  final int fileCount;
  final String totalSizeText;
  final bool isDark;
  final Color textClr;
  final Color secClr;
  final Color mutedClr;
  final List<DownloadTask> tasks;

  const _SummaryCard({
    required this.categoryName,
    required this.categoryColor,
    required this.fileCount,
    required this.totalSizeText,
    required this.isDark,
    required this.textClr,
    required this.secClr,
    required this.mutedClr,
    required this.tasks,
  });

  @override
  Widget build(BuildContext context) {
    // Build status distribution for pie chart
    final completedCount =
        tasks.where((t) => t.status == DownloadStatus.completed).length;
    final failedCount =
        tasks.where((t) => t.status == DownloadStatus.failed).length;

    final List<PieChartSectionData> sections = [];
    if (completedCount > 0) {
      sections.add(PieChartSectionData(
        color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
        value: completedCount.toDouble(),
        radius: 18,
        title: '',
      ));
    }
    if (failedCount > 0) {
      sections.add(PieChartSectionData(
        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
        value: failedCount.toDouble(),
        radius: 18,
        title: '',
      ));
    }
    if (sections.isEmpty) {
      sections.add(PieChartSectionData(
        color: (isDark ? AppTheme.border : AppTheme.lightBorder)
            .withValues(alpha: 0.4),
        value: 1,
        radius: 18,
        title: '',
      ));
    }

    return Semantics(
      label: '$categoryName category: $fileCount files, $totalSizeText',
      child: DmxCardShell(
        accent: categoryColor,
        radius: 20,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Pie Chart
              SizedBox(
                width: 80,
                height: 80,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    PieChart(
                      PieChartData(
                        sections: sections,
                        centerSpaceRadius: 25,
                        sectionsSpace: 2,
                      ),
                    ),
                    Icon(
                      Icons.folder_rounded,
                      size: 14,
                      color: categoryColor.withValues(alpha: 0.7),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),

              // Stats
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      totalSizeText,
                      style: TextStyle(
                        color: textClr,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        fontFamily: 'Space Grotesk',
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$fileCount ${L10n.of(context, 'category_files')}',
                      style: TextStyle(
                        color: mutedClr,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Legend
                    Row(
                      children: [
                        if (completedCount > 0) ...[
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? AppTheme.neonGreen
                                  : AppTheme.lightNeonGreen,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$completedCount done',
                            style: TextStyle(
                              color: secClr,
                              fontSize: 10,
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        if (failedCount > 0) ...[
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? AppTheme.neonRed
                                  : AppTheme.lightNeonRed,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$failedCount failed',
                            style: TextStyle(
                              color: secClr,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
