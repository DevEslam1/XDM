import 'package:flutter/material.dart';
import '../../../../core/utils/file_opener.dart';
import 'package:provider/provider.dart';
import '../../../../core/app_theme.dart';
import '../../../../core/utils/localization.dart';
import '../../../../core/utils/haptic_helper.dart';
import '../../../../shared/widgets/themed_snackbar.dart';
import '../../settings/provider/settings_provider.dart';
import '../../../../shared/widgets/dmx_backdrop_filter.dart';
import '../models/download_task.dart';
import '../provider/download_provider.dart';
import 'status_chip.dart';
import '../../details/screens/details_screen.dart';
import '../../../../core/utils/premium_route.dart';

class DownloadCard extends StatelessWidget with HapticHelper {
  final DownloadTask task;

  const DownloadCard({super.key, required this.task});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DownloadProvider>(context);
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;

    // Determine status colors
    Color statusColor;
    switch (task.status) {
      case DownloadStatus.queued:
        statusColor = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
        break;
      case DownloadStatus.downloading:
        statusColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
        break;
      case DownloadStatus.paused:
        statusColor = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
        break;
      case DownloadStatus.completed:
        statusColor = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
        break;
      case DownloadStatus.failed:
        statusColor = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
        break;
    }

    // Determine category icon
    IconData categoryIcon;
    switch (task.category) {
      case 'Video':
        categoryIcon = Icons.movie_outlined;
        break;
      case 'Audio':
        categoryIcon = Icons.audiotrack_outlined;
        break;
      case 'Document':
        categoryIcon = Icons.description_outlined;
        break;
      case 'Archive':
        categoryIcon = Icons.folder_zip_outlined;
        break;
      case 'APK':
        categoryIcon = Icons.android_outlined;
        break;
      default:
        categoryIcon = Icons.insert_drive_file_outlined;
    }

    final cardBg = settings.classicUi
        ? (isDark ? AppTheme.surface : AppTheme.lightSurface)
        : (task.status == DownloadStatus.downloading
            ? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue).withValues(alpha: 0.06)
            : (isDark ? AppTheme.glassBg : AppTheme.lightGlassBg));
    final cardBorder = settings.classicUi
        ? Border.all(color: isDark ? AppTheme.border : AppTheme.lightBorder, width: 1.0)
        : Border.all(
            color: task.status == DownloadStatus.downloading
                ? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue).withValues(alpha: 0.2)
                : (isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder),
            width: 0.8,
          );
    final cardShadow = (settings.classicUi || task.status != DownloadStatus.downloading || !isDark)
        ? null
        : [
            BoxShadow(
              color: AppTheme.neonBlue.withValues(alpha: 0.06),
              blurRadius: 16.0,
              spreadRadius: 0,
            ),
          ];

    final cardBody = Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: cardBorder,
        boxShadow: cardShadow,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            triggerHaptic(settings);
            Navigator.push(
              context,
              PremiumPageRoute(
                type: PageTransitionType.slideRight,
                child: DetailsScreen(taskId: task.id),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top row: File info + Control buttons
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // File category icon
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: statusColor.withValues(alpha: 0.15),
                          width: 0.8,
                        ),
                      ),
                      child: Icon(
                        categoryIcon,
                        color: statusColor.withValues(alpha: 0.85),
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    // File name and status chip
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.fileName,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              StatusChip(task: task),
                              Text(
                                L10n.translateCategory(context, task.category).toUpperCase(),
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.8,
                                      color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                                    ),
                              ),
                              if (task.isTorrent &&
                                  (task.status == DownloadStatus.downloading ||
                                      (task.status == DownloadStatus.completed && task.seedingEnabled))) ...[
                                Text(
                                  '|',
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                                  ),
                                ),
                                Text(
                                  '${L10n.of(context, 'seeds')}: ${provider.getTorrentSeeds(task.id)}',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                                      ),
                                ),
                                Text(
                                  '${L10n.of(context, 'peers')}: ${provider.getTorrentPeers(task.id)}',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                                      ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Action controls
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (task.status == DownloadStatus.downloading)
                          IconButton(
                            icon: Icon(
                              Icons.pause,
                              color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                              size: 20,
                            ),
                            onPressed: () {
                              triggerHaptic(settings);
                              provider.pauseTask(task.id);
                            },
                            tooltip: 'Pause Download',
                          )
                        else if (task.status == DownloadStatus.paused ||
                            task.status == DownloadStatus.queued)
                          IconButton(
                            icon: Icon(
                              Icons.play_arrow,
                              color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                              size: 20,
                            ),
                            onPressed: () {
                              triggerHaptic(settings);
                              provider.resumeTask(task.id);
                            },
                            tooltip: 'Resume Download',
                          )
                        else if (task.status == DownloadStatus.failed)
                          IconButton(
                            icon: Icon(
                              Icons.refresh,
                              color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                              size: 20,
                            ),
                            onPressed: () {
                              triggerHaptic(settings);
                              provider.retryTask(task.id);
                            },
                            tooltip: 'Retry Download',
                          )
                        else if (task.status == DownloadStatus.completed) ...[
                          if (task.isTorrent)
                            IconButton(
                              icon: Icon(
                                task.seedingEnabled ? Icons.pause : Icons.play_arrow,
                                color: task.seedingEnabled
                                    ? (isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary)
                                    : (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue),
                                size: 20,
                              ),
                              onPressed: () {
                                triggerHaptic(settings);
                                provider.updateTaskSeeding(task.id, enabled: !task.seedingEnabled);
                              },
                              tooltip: task.seedingEnabled ? 'Pause Seeding' : 'Start Seeding',
                            ),
                          IconButton(
                            icon: Icon(
                              Icons.folder_open_outlined,
                              color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                              size: 20,
                            ),
                            onPressed: () {
                              triggerHaptic(settings);
                              openFile(context, task.localFilePath, settings);
                            },
                            tooltip: 'Open File',
                          ),
                        ],
                        IconButton(
                          icon: Icon(
                            Icons.close,
                            color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                            size: 18,
                          ),
                          onPressed: () async {
                            triggerHaptic(settings);
                            final deleteFiles = await _showDeleteConfirmationDialog(context, task, settings);
                            if (deleteFiles != null) {
                              provider.deleteTask(task.id, deleteFiles: deleteFiles);
                              if (context.mounted) {
                                ThemedSnackbar.show(
                                  context,
                                  message: L10n.isRtl(context) ? 'تم حذف التنزيل بنجاح' : 'Download deleted successfully',
                                  color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                                  icon: Icons.delete,
                                  isDarkMode: isDark,
                                );
                              }
                            }
                          },
                          tooltip: 'Delete Task',
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                // Segmented Progress Bar for Chunks
                Builder(
                  builder: (context) {
                    final showSplitBar = (task.status == DownloadStatus.downloading || task.status == DownloadStatus.paused) &&
                        task.chunks.isNotEmpty &&
                        task.chunks.length > 1;

                    if (showSplitBar) {
                      return Row(
                        children: List.generate(task.chunks.length, (index) {
                          final chunkProgress = task.chunks[index];
                          return Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(
                                left: index == 0 ? 0.0 : 2.0,
                                right: index == task.chunks.length - 1 ? 0.0 : 2.0,
                              ),
                              child: Stack(
                                children: [
                                  Container(
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                  if (chunkProgress > 0)
                                    AnimatedFractionallySizedBox(
                                      widthFactor: chunkProgress,
                                      duration: const Duration(milliseconds: 300),
                                      curve: Curves.easeOutCubic,
                                      child: Container(
                                        height: 6,
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(4),
                                          boxShadow: task.status == DownloadStatus.downloading && isDark && !settings.classicUi
                                              ? [
                                                  BoxShadow(
                                                    color: statusColor.withValues(
                                                      alpha: 0.4,
                                                    ),
                                                    blurRadius: 4.0,
                                                    spreadRadius: 0.5,
                                                  ),
                                                ]
                                              : null,
                                          gradient: LinearGradient(
                                            colors: [
                                              statusColor,
                                              statusColor.withValues(alpha: 0.7),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        }),
                      );
                    }

                    // Otherwise, render the standard continuous progress bar
                    return TweenAnimationBuilder<double>(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                      tween: Tween<double>(begin: 0.0, end: task.progress),
                      builder: (context, val, child) {
                        return Stack(
                          children: [
                            Container(
                              height: 6,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            if (val > 0)
                              FractionallySizedBox(
                                widthFactor: val,
                                child: Container(
                                  height: 6,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    boxShadow: task.status == DownloadStatus.downloading && isDark && !settings.classicUi
                                        ? [
                                            BoxShadow(
                                              color: statusColor.withValues(
                                                alpha: 0.5,
                                              ),
                                              blurRadius: 6.0,
                                              spreadRadius: 0.5,
                                            ),
                                          ]
                                        : null,
                                    gradient: LinearGradient(
                                      colors: [
                                        statusColor,
                                        statusColor.withValues(alpha: 0.7),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 10),
                // Footer metadata
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Size progress
                    Text(
                      '${task.downloadedSizeFormatted} / ${task.sizeFormatted}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                        fontSize: 11,
                      ),
                    ),
                    // Progress percent
                    Text(
                      task.progressPercentString,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                    // ETA or status message
                    Row(
                      children: [
                        if (task.status == DownloadStatus.downloading || (task.status == DownloadStatus.completed && task.isTorrent && task.seedingEnabled)) ...[
                          Icon(
                            (task.status == DownloadStatus.completed) ? Icons.upload : Icons.download,
                            size: 12,
                            color: (task.status == DownloadStatus.completed)
                                ? (isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet)
                                : (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            task.speedFormatted,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: (task.status == DownloadStatus.completed)
                                      ? (isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet)
                                      : (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue),
                                  fontWeight: FontWeight.w600,
                                  fontSize: 11,
                                ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Icon(
                          (task.status == DownloadStatus.completed && task.isTorrent && task.seedingEnabled)
                              ? Icons.cloud_upload_outlined
                              : (task.status == DownloadStatus.completed
                                  ? Icons.check_circle_outline
                                  : Icons.schedule),
                          size: 12,
                          color: (task.status == DownloadStatus.completed && task.isTorrent && task.seedingEnabled)
                              ? (isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet)
                              : (task.status == DownloadStatus.completed
                                  ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
                                  : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted)),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          L10n.translateStatus(context, task.status, task.etaFormatted),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: (task.status == DownloadStatus.completed && task.isTorrent && task.seedingEnabled)
                                    ? (isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet)
                                    : (task.status == DownloadStatus.completed
                                        ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
                                        : (isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary)),
                                fontSize: 11,
                              ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Dismissible(
      key: Key(task.id),
      direction: DismissDirection.horizontal,
      background: Container(
        margin: const EdgeInsets.only(bottom: 12),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 24.0),
        decoration: BoxDecoration(
          color: (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(
          task.status == DownloadStatus.downloading ? Icons.pause : Icons.play_arrow,
          color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        ),
      ),
      secondaryBackground: Container(
        margin: const EdgeInsets.only(bottom: 12),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24.0),
        decoration: BoxDecoration(
          color: (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(
          Icons.delete_outline,
          color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
        ),
      ),
      confirmDismiss: (direction) async {
        triggerHaptic(settings);
        if (direction == DismissDirection.endToStart) {
          final deleteFiles = await _showDeleteConfirmationDialog(context, task, settings);
          if (deleteFiles != null) {
            provider.deleteTask(task.id, deleteFiles: deleteFiles);
            if (context.mounted) {
              ThemedSnackbar.show(
                context,
                message: L10n.isRtl(context) ? 'تم حذف التنزيل بنجاح' : 'Download deleted successfully',
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                icon: Icons.delete,
                isDarkMode: isDark,
              );
            }
            return true;
          }
          return false;
        } else {
          if (task.status == DownloadStatus.downloading) {
            provider.pauseTask(task.id);
          } else if (task.status == DownloadStatus.paused || task.status == DownloadStatus.queued) {
            provider.resumeTask(task.id);
          } else if (task.status == DownloadStatus.failed) {
            provider.retryTask(task.id);
          }
          return false;
        }
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: settings.classicUi
            ? cardBody
            : ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: DmxBackdropFilter(
                  sigmaX: 10,
                  sigmaY: 10,
                  child: cardBody,
                ),
              ),
      ),
    );
  }

  Future<bool?> _showDeleteConfirmationDialog(
    BuildContext context,
    DownloadTask task,
    SettingsProvider settings,
  ) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    bool deleteFiles = false;

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return Directionality(
              textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
              child: AlertDialog(
                backgroundColor: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.92),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, width: 0.8),
                ),
                title: Text(
                  L10n.of(context, 'delete_title'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isRtl
                          ? 'هل أنت متأكد من حذف "${task.fileName}" من القائمة؟'
                          : 'Are you sure you want to remove "${task.fileName}" from the list?',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: Checkbox(
                            value: deleteFiles,
                            activeColor: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                            side: BorderSide(
                              color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                              width: 1.0,
                            ),
                            onChanged: (val) {
                              if (val != null) {
                                triggerHaptic(settings);
                                setState(() {
                                  deleteFiles = val;
                                });
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              triggerHaptic(settings);
                              setState(() {
                                deleteFiles = !deleteFiles;
                              });
                            },
                            child: Text(
                              L10n.of(context, 'delete_files_label'),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    style: TextButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text(
                      L10n.of(context, 'cancel_btn'),
                      style: TextStyle(color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text(
                      L10n.of(context, 'delete_btn'),
                      style: TextStyle(
                        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onPressed: () => Navigator.of(context).pop({'confirmed': true, 'deleteFiles': deleteFiles}),
                  ),
                ],
              ),
            );
          }
        );
      },
    ).then((result) {
      if (result != null && result['confirmed'] == true) {
        return result['deleteFiles'] as bool;
      }
      return null;
    });
  }
}
