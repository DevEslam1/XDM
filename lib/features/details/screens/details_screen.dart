import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/utils/file_opener.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../settings/provider/settings_provider.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../widgets/circular_progress_widget.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/constants.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../core/utils/file_utils.dart';

class DetailsScreen extends StatelessWidget with HapticHelper {
  final String taskId;

  const DetailsScreen({super.key, required this.taskId});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
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
          title: Text(
            L10n.of(context, 'details_title'),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              fontSize: 16,
            ),
          ),
          leading: IconButton(
            icon: Icon(
              isRtl ? Icons.arrow_forward_ios : Icons.arrow_back_ios_new,
              size: 18,
              color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
            ),
            onPressed: () {
              triggerHaptic(settings);
              Navigator.pop(context);
            },
          ),
        ),
        body: Consumer<DownloadProvider>(
          builder: (context, provider, child) {
            final taskIndex = provider.tasks.indexWhere((t) => t.id == taskId);
            if (taskIndex == -1) {
              return Center(
                child: Text(
                  isRtl ? 'مهمة التنزيل غير موجودة' : 'DOWNLOAD TASK NOT FOUND',
                  style: TextStyle(
                    color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            }

            final task = provider.tasks[taskIndex];
            final isSeeding = task.status == DownloadStatus.completed && task.isTorrent && task.seedingEnabled;
            final isDownloadingTorrent = task.status == DownloadStatus.downloading && task.isTorrent;

            String speedTextInsideCircle;
            if (isDownloadingTorrent) {
              final ulSpeed = provider.getTorrentUploadSpeed(task.id);
              speedTextInsideCircle = 'DL: ${task.speedFormatted} | UL: ${formatBytes(ulSpeed)}/s';
            } else if (isSeeding) {
              speedTextInsideCircle = 'UL: ${task.speedFormatted}';
            } else {
              speedTextInsideCircle = task.status == DownloadStatus.downloading
                  ? task.speedFormatted
                  : L10n.translateStatusName(context, task.status).toUpperCase();
            }

            // Status colors
            Color statusColor;
            switch (task.status) {
              case DownloadStatus.queued:
                statusColor = isDark
                    ? AppTheme.neonViolet
                    : AppTheme.lightNeonViolet;
                break;
              case DownloadStatus.downloading:
                statusColor = isDark
                    ? AppTheme.neonBlue
                    : AppTheme.lightNeonBlue;
                break;
              case DownloadStatus.paused:
                statusColor = isDark
                    ? AppTheme.neonAmber
                    : AppTheme.lightNeonAmber;
                break;
              case DownloadStatus.completed:
                statusColor = isDark
                    ? AppTheme.neonGreen
                    : AppTheme.lightNeonGreen;
                break;
              case DownloadStatus.failed:
                statusColor = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
                break;
            }

            return Directionality(
              textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
              child: SafeArea(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(height: 10),
                      // Large circular progress speedometer
                      Center(
                        child: CircularProgressWidget(
                          progress: task.progress,
                          speedText: speedTextInsideCircle,
                          etaText: (task.status == DownloadStatus.downloading || isSeeding)
                              ? L10n.translateStatus(
                                  context,
                                  task.status,
                                  task.etaFormatted,
                                )
                              : L10n.of(context, 'details_inactive_eta'),
                          accentColor: statusColor,
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Controls panel
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (task.status == DownloadStatus.downloading)
                            NeonGlowButton(
                              onPressed: () {
                                triggerHaptic(settings);
                                provider.pauseTask(task.id);
                              },
                              text: isRtl ? 'إيقاف' : 'PAUSE',
                              icon: Icons.pause,
                              color: isDark
                                  ? AppTheme.neonAmber
                                  : AppTheme.lightNeonAmber,
                            )
                          else if (task.status == DownloadStatus.paused ||
                              task.status == DownloadStatus.queued)
                            NeonGlowButton(
                              onPressed: () {
                                triggerHaptic(settings);
                                provider.resumeTask(task.id);
                              },
                              text: task.status == DownloadStatus.queued
                                  ? (isRtl ? 'بدء' : 'START')
                                  : (isRtl ? 'استئناف' : 'RESUME'),
                              icon: Icons.play_arrow,
                              color: isDark
                                  ? AppTheme.neonBlue
                                  : AppTheme.lightNeonBlue,
                              isFilled: true,
                            )
                          else if (task.status == DownloadStatus.failed)
                            NeonGlowButton(
                              onPressed: () {
                                triggerHaptic(settings);
                                provider.retryTask(task.id);
                              },
                              text: isRtl ? 'إعادة' : 'RETRY',
                              icon: Icons.refresh,
                              color: isDark
                                  ? AppTheme.neonViolet
                                  : AppTheme.lightNeonViolet,
                              isFilled: true,
                            )
                          else if (task.status == DownloadStatus.completed)
                            NeonGlowButton(
                              onPressed: () {
                                triggerHaptic(settings);
                                openFile(context, task.localFilePath, settings);
                              },
                              text: isRtl ? 'فتح الملف' : 'OPEN FILE',
                              icon: Icons.folder_open_outlined,
                              color: isDark
                                  ? AppTheme.neonGreen
                                  : AppTheme.lightNeonGreen,
                              isFilled: true,
                            ),
                          const SizedBox(width: 16),
                          NeonGlowButton(
                            onPressed: () async {
                              triggerHaptic(settings);
                              final deleteFiles =
                                  await _showDeleteConfirmationDialog(
                                    context,
                                    task,
                                    settings,
                                  );
                              if (deleteFiles != null) {
                                provider.deleteTask(
                                  task.id,
                                  deleteFiles: deleteFiles,
                                );
                                if (context.mounted) {
                                  ThemedSnackbar.show(
                                    context,
                                    message: isRtl
                                        ? 'تم حذف التنزيل بنجاح'
                                        : 'Download deleted successfully',
                                    color: isDark
                                        ? AppTheme.neonRed
                                        : AppTheme.lightNeonRed,
                                    icon: Icons.delete,
                                    isDarkMode: isDark,
                                  );
                                  Navigator.pop(context);
                                }
                              }
                            },
                            text: L10n.of(context, 'delete_btn'),
                            icon: Icons.delete_outline,
                            color: isDark
                                ? AppTheme.neonRed
                                : AppTheme.lightNeonRed,
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),

                      // Connection Channels / Chunks Visualizer or Torrent Stats Panel
                      if (task.isTorrent) ...[
                        _buildTorrentStatsPanel(
                          context,
                          task,
                          provider,
                          settings,
                        ),
                        const SizedBox(height: 20),
                      ] else ...[
                        _buildChannelsPanel(
                          context,
                          task,
                          provider,
                          statusColor,
                          settings,
                        ),
                        const SizedBox(height: 20),
                      ],

                      // Individual Speed and Seeding Controls Panel
                      _buildTaskBandwidthPanel(
                        context,
                        task,
                        provider,
                        settings,
                      ),
                      const SizedBox(height: 20),

                      // Telemetry Speed History Graph
                      _buildSpeedGraphPanel(context, task, provider, settings),
                      const SizedBox(height: 20),

                      // Torrent files checklist & status
                      _buildTorrentFilesPanel(
                        context,
                        task,
                        provider,
                        settings,
                      ),

                      // File Metadata Panel
                      _buildMetadataPanel(context, task, provider, settings),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSpeedGraphPanel(
    BuildContext context,
    DownloadTask task,
    DownloadProvider provider,
    SettingsProvider settings,
  ) {
    final isDark = settings.isDarkMode;
    final secClr = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;
    final primaryClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    final speedHistory = provider.getSpeedHistory(task.id);
    final isDownloading = task.status == DownloadStatus.downloading;

    // Map speed records to fl_chart points
    final List<FlSpot> spots = List.generate(speedHistory.length, (i) {
      // Map to MB/s
      return FlSpot(i.toDouble(), speedHistory[i] / (1024 * 1024));
    });

    return GlassCard(
      borderRadius: 20,
      padding: const EdgeInsets.all(16),
      isDarkMode: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L10n.isRtl(context) ? 'مخطط سرعة التنزيل' : 'DOWNLOAD SPEED CHART',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: secClr,
              fontSize: 10,
              letterSpacing: 1.0,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          if (!isDownloading || spots.isEmpty)
            Container(
              height: 120,
              alignment: Alignment.center,
              child: Text(
                isDownloading
                    ? (L10n.isRtl(context)
                          ? 'جاري تجميع البيانات...'
                          : 'AWAITING DOWNLOAD SPEED DATA...')
                    : (L10n.isRtl(context)
                          ? 'محرك التنزيل غير نشط'
                          : 'DOWNLOAD ENGINE INACTIVE'),
                style: TextStyle(
                  color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                  fontFamily: 'monospace',
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          else
            SizedBox(
              height: 120,
              child: LineChart(
                LineChartData(
                  gridData: const FlGridData(show: false),
                  titlesData: const FlTitlesData(show: false),
                  borderData: FlBorderData(show: false),
                  lineTouchData: const LineTouchData(enabled: false),
                  minX: 0,
                  maxX: spots.length.toDouble() - 1,
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      color: primaryClr,
                      barWidth: 2.5,
                      isStrokeCapRound: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            primaryClr.withValues(alpha: 0.2),
                            primaryClr.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _changeThreadCount(
    BuildContext context,
    DownloadTask task,
    DownloadProvider provider,
    SettingsProvider settings,
    int newCount,
  ) {
    if (task.threadCount == newCount) return;

    final isRtl = L10n.isRtl(context);
    final isDark = settings.isDarkMode;

    if (task.downloadedBytes > 0) {
      showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            backgroundColor: isDark ? AppTheme.surface : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: isDark
                    ? AppTheme.glassBorder
                    : AppTheme.lightGlassBorder,
              ),
            ),
            title: Text(
              L10n.of(context, 'details_threads_warning_title'),
              style: TextStyle(
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            content: Text(
              L10n.of(context, 'details_threads_warning_desc'),
              style: TextStyle(
                color: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary,
                fontSize: 14,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  triggerHaptic(settings);
                  Navigator.pop(context);
                },
                child: Text(
                  L10n.of(context, 'cancel_btn'),
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.textMuted
                        : AppTheme.lightTextMuted,
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
                  triggerHaptic(settings);
                  Navigator.pop(context);
                  provider.updateTaskThreadCount(task.id, newCount);
                },
                child: Text(
                  isRtl ? 'نعم، أعد التعيين' : 'YES, RESET',
                  style: TextStyle(
                    color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          );
        },
      );
    } else {
      provider.updateTaskThreadCount(task.id, newCount);
    }
  }

  Widget _buildChannelsPanel(
    BuildContext context,
    DownloadTask task,
    DownloadProvider provider,
    Color statusColor,
    SettingsProvider settings,
  ) {
    final isDark = settings.isDarkMode;
    final secClr = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;
    final borderClr = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
    final isRtl = L10n.isRtl(context);

    return GlassCard(
      borderRadius: 20,
      padding: const EdgeInsets.all(16),
      isDarkMode: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                L10n.of(context, 'details_channels'),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: secClr,
                  fontSize: 10,
                  letterSpacing: 1.0,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '${task.chunks.length} ${isRtl ? 'قنوات نشطة' : L10n.of(context, 'details_active_threads')}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: statusColor,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Thread Adjuster Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isRtl ? 'تعديل خيوط الاتصال' : 'ADJUST CONNECTION THREADS',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Row(
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () {
                      final list = kAvailableThreadOptions;
                      final curIdx = list.indexOf(task.threadCount);
                      if (curIdx > 0) {
                        _changeThreadCount(
                          context,
                          task,
                          provider,
                          settings,
                          list[curIdx - 1],
                        );
                      }
                    },
                    icon: Icon(
                      Icons.remove_circle_outline,
                      size: 20,
                      color: task.threadCount > 1
                          ? statusColor
                          : (isDark
                                ? AppTheme.textMuted
                                : AppTheme.lightTextMuted),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: borderClr.withValues(alpha: 0.1),
                      border: Border.all(color: borderClr),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${task.threadCount}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: isDark
                            ? AppTheme.textPrimary
                            : AppTheme.lightTextPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () {
                      final list = kAvailableThreadOptions;
                      final curIdx = list.indexOf(task.threadCount);
                      if (curIdx != -1 && curIdx < list.length - 1) {
                        _changeThreadCount(
                          context,
                          task,
                          provider,
                          settings,
                          list[curIdx + 1],
                        );
                      }
                    },
                    icon: Icon(
                      Icons.add_circle_outline,
                      size: 20,
                      color: task.threadCount < 16
                          ? statusColor
                          : (isDark
                                ? AppTheme.textMuted
                                : AppTheme.lightTextMuted),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Column(
            children: List.generate(task.chunks.length, (index) {
              final chunkProgress = task.chunks[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10.0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 48,
                      child: Text(
                        isRtl ? 'قناة ${index + 1}' : 'CH ${index + 1}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: secClr,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          Container(
                            height: 6,
                            decoration: BoxDecoration(
                              color: borderClr.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          FractionallySizedBox(
                            widthFactor: chunkProgress,
                            child: Container(
                              height: 6,
                              decoration: BoxDecoration(
                                color: task.status == DownloadStatus.downloading
                                    ? statusColor
                                    : (isDark
                                          ? AppTheme.textMuted
                                          : AppTheme.lightTextMuted),
                                borderRadius: BorderRadius.circular(6),
                                boxShadow:
                                    task.status == DownloadStatus.downloading &&
                                        isDark
                                    ? [
                                        BoxShadow(
                                          color: statusColor.withValues(
                                            alpha: 0.4,
                                          ),
                                          blurRadius: 4.0,
                                        ),
                                      ]
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 38,
                      child: Text(
                        '${(chunkProgress * 100).toStringAsFixed(0)}%',
                        textAlign: isRtl ? TextAlign.left : TextAlign.right,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: 10,
                          color: task.status == DownloadStatus.downloading
                              ? statusColor
                              : secClr,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataPanel(
    BuildContext context,
    DownloadTask task,
    DownloadProvider provider,
    SettingsProvider settings,
  ) {
    final isDark = settings.isDarkMode;
    final secClr = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;

    return GlassCard(
      borderRadius: 20,
      padding: const EdgeInsets.all(16),
      isDarkMode: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L10n.of(context, 'details_metadata'),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: secClr,
              fontSize: 10,
              letterSpacing: 1.0,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          _buildMetaRow(
            context,
            label: L10n.of(context, 'details_filename'),
            value: task.fileName,
            settings: settings,
          ),
          _buildMetaRow(
            context,
            label: L10n.of(context, 'details_url'),
            value: task.url,
            isUrl: true,
            settings: settings,
            onEditPressed: () {
              _showUpdateUrlDialog(context, task, provider, settings);
            },
            onCopyPressed: () {
              Clipboard.setData(ClipboardData(text: task.url));
              ThemedSnackbar.show(
                context,
                message: L10n.isRtl(context)
                    ? 'تم نسخ الرابط'
                    : 'URL copied to clipboard',
                color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                icon: Icons.check_circle_outline,
                isDarkMode: isDark,
              );
            },
          ),
          if (task.downloadPageUrl != null && task.downloadPageUrl!.isNotEmpty)
            _buildMetaRow(
              context,
              label: L10n.isRtl(context)
                  ? 'صفحة التنزيل الأصلية'
                  : 'ORIGIN DOWNLOAD PAGE',
              value: task.downloadPageUrl!,
              isUrl: true,
              settings: settings,
              onCopyPressed: () {
                Clipboard.setData(ClipboardData(text: task.downloadPageUrl!));
                ThemedSnackbar.show(
                  context,
                  message: L10n.isRtl(context)
                      ? 'تم نسخ رابط الصفحة'
                      : 'Page URL copied to clipboard',
                  color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                  icon: Icons.check_circle_outline,
                  isDarkMode: isDark,
                );
              },
              onOpenPressed: () {
                provider.openUrlInBrowser(task.downloadPageUrl!);
                Navigator.pop(context);
              },
            ),
          _buildMetaRow(
            context,
            label: L10n.of(context, 'details_path'),
            value: task.savePath,
            settings: settings,
          ),
          _buildMetaRow(
            context,
            label: L10n.of(context, 'details_local_file'),
            value: task.localFilePath,
            settings: settings,
          ),
          _buildMetaRow(
            context,
            label: L10n.of(context, 'details_size'),
            value: task.sizeFormatted,
            settings: settings,
          ),
          _buildMetaRow(
            context,
            label: L10n.of(context, 'details_transferred'),
            value: task.downloadedSizeFormatted,
            settings: settings,
          ),
          _buildMetaRow(
            context,
            label: L10n.of(context, 'details_category'),
            value: L10n.translateCategory(context, task.category).toUpperCase(),
            settings: settings,
          ),
          if (task.errorMessage != null)
            _buildMetaRow(
              context,
              label: L10n.of(context, 'details_error'),
              value: _translateErrorMessage(context, task.errorMessage!),
              settings: settings,
            ),
          _buildMetaRow(
            context,
            label: L10n.of(context, 'details_established'),
            value: task.createdAt.toLocal().toString().split('.')[0],
            settings: settings,
          ),
        ],
      ),
    );
  }

  Widget _buildMetaRow(
    BuildContext context, {
    required String label,
    required String value,
    bool isUrl = false,
    required SettingsProvider settings,
    VoidCallback? onEditPressed,
    VoidCallback? onCopyPressed,
    VoidCallback? onOpenPressed,
  }) {
    final isDark = settings.isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 9,
              color: mutedClr,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontSize: 12,
                    color: textClr,
                    fontWeight: isUrl ? FontWeight.normal : FontWeight.bold,
                  ),
                  maxLines: isUrl ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onEditPressed != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  onPressed: onEditPressed,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  visualDensity: VisualDensity.compact,
                  tooltip: L10n.isRtl(context) ? 'تحديث الرابط' : 'Update URL',
                ),
              ],
              if (onCopyPressed != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  onPressed: onCopyPressed,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  visualDensity: VisualDensity.compact,
                  tooltip: L10n.isRtl(context) ? 'نسخ الرابط' : 'Copy URL',
                ),
              ],
              if (onOpenPressed != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  onPressed: onOpenPressed,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  visualDensity: VisualDensity.compact,
                  tooltip: L10n.isRtl(context)
                      ? 'فتح في المتصفح'
                      : 'Open in Browser',
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  String _translateErrorMessage(BuildContext context, String err) {
    if (!L10n.isRtl(context)) return err;
    if (err.contains('Waiting for WiFi')) {
      return 'في انتظار اتصال الواي فاي';
    }
    if (err.contains('Transfer cancelled')) {
      return 'تم إلغاء النقل';
    }
    return err;
  }

  Widget _buildTaskBandwidthPanel(
    BuildContext context,
    DownloadTask task,
    DownloadProvider provider,
    SettingsProvider settings,
  ) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final borderClr = isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;

    final hasLimit = task.speedLimitKbps > 0;

    return GlassCard(
      borderRadius: 20,
      padding: const EdgeInsets.all(16),
      isDarkMode: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.speed, color: blueClr, size: 18),
              const SizedBox(width: 8),
              Text(
                isRtl ? 'التحكم في سرعة التحميل' : 'BANDWIDTH SPEED CONTROLS',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: secClr,
                  fontSize: 10,
                  letterSpacing: 1.0,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isRtl ? 'حد التحميل الأقصى' : 'DOWNLOAD SPEED LIMIT',
                    style: TextStyle(
                      color: textClr,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hasLimit
                        ? '${task.speedLimitKbps} kbps (${(task.speedLimitKbps / 8).toStringAsFixed(1)} KB/s)'
                        : (isRtl ? 'غير محدود' : 'UNLIMITED SPEED'),
                    style: TextStyle(
                      color: hasLimit ? blueClr : secClr,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              Switch(
                value: hasLimit,
                activeThumbColor: blueClr,
                onChanged: (val) {
                  triggerHaptic(settings);
                  provider.updateTaskSpeedLimit(task.id, val ? 500 : 0);
                },
              ),
            ],
          ),
          if (hasLimit) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildSpeedStepButton(
                  context: context,
                  label: '-100 kbps',
                  isDark: isDark,
                  onPressed: task.speedLimitKbps <= 100
                      ? null
                      : () {
                          triggerHaptic(settings);
                          provider.updateTaskSpeedLimit(
                            task.id,
                            task.speedLimitKbps - 100,
                          );
                        },
                ),
                const SizedBox(width: 16),
                _buildSpeedStepButton(
                  context: context,
                  label: '+100 kbps',
                  isDark: isDark,
                  onPressed: () {
                    triggerHaptic(settings);
                    provider.updateTaskSpeedLimit(
                      task.id,
                      task.speedLimitKbps + 100,
                    );
                  },
                ),
              ],
            ),
          ],

          if (task.isTorrent) ...[
            const SizedBox(height: 16),
            Divider(color: borderClr, height: 1),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.cloud_upload_outlined, color: violetClr, size: 18),
                const SizedBox(width: 8),
                Text(
                  isRtl
                      ? 'إعدادات مشاركة التورنت (Seeding)'
                      : 'TORRENT SEEDING INTERFACE',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: secClr,
                    fontSize: 10,
                    letterSpacing: 1.0,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isRtl
                          ? 'تفعيل المشاركة (Seeding)'
                          : 'SEEDING TRANSMISSION',
                      style: TextStyle(
                        color: textClr,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      task.seedingEnabled
                          ? (isRtl
                                ? 'نشط عند اكتمال التحميل'
                                : 'ACTIVE ON COMPLETION')
                          : (isRtl ? 'غير نشط' : 'DISABLED'),
                      style: TextStyle(
                        color: task.seedingEnabled ? violetClr : secClr,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                Switch(
                  value: task.seedingEnabled,
                  activeThumbColor: violetClr,
                  onChanged: (val) {
                    triggerHaptic(settings);
                    provider.updateTaskSeeding(task.id, enabled: val);
                  },
                ),
              ],
            ),
            if (task.seedingEnabled) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isRtl ? 'تقييد سرعة الرفع' : 'LIMIT UPLOAD SPEED',
                        style: TextStyle(
                          color: textClr,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        task.seedingLimited
                            ? '${task.seedingLimitKbps} kbps (${(task.seedingLimitKbps / 8).toStringAsFixed(1)} KB/s)'
                            : (isRtl ? 'سرعة رفع قصوى' : 'UNLIMITED UPLOAD'),
                        style: TextStyle(
                          color: task.seedingLimited ? violetClr : secClr,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                  Switch(
                    value: task.seedingLimited,
                    activeThumbColor: violetClr,
                    onChanged: (val) {
                      triggerHaptic(settings);
                      provider.updateTaskSeeding(task.id, limited: val);
                    },
                  ),
                ],
              ),
              if (task.seedingLimited) ...[
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildSpeedStepButton(
                      context: context,
                      label: '-100 kbps',
                      isDark: isDark,
                      onPressed: task.seedingLimitKbps <= 100
                          ? null
                          : () {
                              triggerHaptic(settings);
                              provider.updateTaskSeeding(
                                task.id,
                                limitKbps: task.seedingLimitKbps - 100,
                              );
                            },
                    ),
                    const SizedBox(width: 16),
                    _buildSpeedStepButton(
                      context: context,
                      label: '+100 kbps',
                      isDark: isDark,
                      onPressed: () {
                        triggerHaptic(settings);
                        provider.updateTaskSeeding(
                          task.id,
                          limitKbps: task.seedingLimitKbps + 100,
                        );
                      },
                    ),
                  ],
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildSpeedStepButton({
    required BuildContext context,
    required String label,
    required bool isDark,
    required VoidCallback? onPressed,
  }) {
    final activeClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: activeClr,
        side: BorderSide(color: activeClr.withValues(alpha: 0.3)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      onPressed: onPressed,
      child: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
      ),
    );
  }

  Widget _buildTorrentFilesPanel(
    BuildContext context,
    DownloadTask task,
    DownloadProvider provider,
    SettingsProvider settings,
  ) {
    if (!task.isTorrent ||
        task.torrentFiles == null ||
        task.torrentFiles!.isEmpty) {
      return const SizedBox.shrink();
    }
    return _TorrentFilesPanel(
      task: task,
      provider: provider,
      settings: settings,
    );
  }

  void _showUpdateUrlDialog(
    BuildContext context,
    DownloadTask task,
    DownloadProvider provider,
    SettingsProvider settings,
  ) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final textController = TextEditingController(text: task.url);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
            ),
          ),
          title: Text(
            isRtl ? 'تحديث رابط التحميل' : 'UPDATE DOWNLOAD LINK',
            style: TextStyle(
              color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isRtl
                    ? 'أدخل الرابط الجديد لمتابعة التحميل:'
                    : 'Enter the new URL to continue downloading:',
                style: TextStyle(
                  color: isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: textController,
                maxLines: 3,
                style: TextStyle(
                  color: isDark
                      ? AppTheme.textPrimary
                      : AppTheme.lightTextPrimary,
                  fontSize: 12,
                ),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: isDark
                      ? const Color(0xFF0F0F16)
                      : const Color(0xFFF1F5F9),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(
                      color: isDark
                          ? const Color(0x15FFFFFF)
                          : const Color(0x0D000000),
                      width: 0.8,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(
                      color: isDark
                          ? const Color(0x15FFFFFF)
                          : const Color(0x0D000000),
                      width: 0.8,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(
                      color:
                          (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue)
                              .withValues(alpha: 0.5),
                      width: 1.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                triggerHaptic(settings);
                Navigator.pop(context);
              },
              child: Text(
                L10n.of(context, 'cancel_btn'),
                style: TextStyle(
                  color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark
                    ? AppTheme.neonBlue.withValues(alpha: 0.2)
                    : AppTheme.lightNeonBlue.withValues(alpha: 0.1),
                side: BorderSide(
                  color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () async {
                triggerHaptic(settings);
                final newUrl = textController.text.trim();
                if (newUrl.isEmpty) return;

                Navigator.pop(context);
                try {
                  await provider.updateTaskUrl(task.id, newUrl);
                  if (context.mounted) {
                    ThemedSnackbar.show(
                      context,
                      message: isRtl
                          ? 'تم تحديث الرابط بنجاح. يمكنك استئناف التحميل الآن.'
                          : 'Link updated successfully. You can resume download now.',
                      color: isDark
                          ? AppTheme.neonGreen
                          : AppTheme.lightNeonGreen,
                      icon: Icons.check_circle_outline,
                      isDarkMode: isDark,
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ThemedSnackbar.show(
                      context,
                      message: e.toString(),
                      color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                      icon: Icons.error_outline,
                      isDarkMode: isDark,
                    );
                  }
                }
              },
              child: Text(
                isRtl ? 'تحديث' : 'UPDATE',
                style: TextStyle(
                  color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
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
                backgroundColor:
                    (isDark ? AppTheme.surface : AppTheme.lightSurface)
                        .withValues(alpha: 0.92),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(
                    color: isDark
                        ? AppTheme.glassBorder
                        : AppTheme.lightGlassBorder,
                    width: 0.8,
                  ),
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
                        color: isDark
                            ? AppTheme.textSecondary
                            : AppTheme.lightTextSecondary,
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
                            activeColor: isDark
                                ? AppTheme.neonRed
                                : AppTheme.lightNeonRed,
                            side: BorderSide(
                              color: isDark
                                  ? AppTheme.glassBorder
                                  : AppTheme.lightGlassBorder,
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
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: isDark
                                        ? AppTheme.textPrimary
                                        : AppTheme.lightTextPrimary,
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
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      L10n.of(context, 'cancel_btn'),
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.textSecondary
                            : AppTheme.lightTextSecondary,
                      ),
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
                      L10n.of(context, 'delete_btn'),
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.neonRed
                            : AppTheme.lightNeonRed,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onPressed: () => Navigator.of(
                      context,
                    ).pop({'confirmed': true, 'deleteFiles': deleteFiles}),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).then((result) {
      if (result != null && result['confirmed'] == true) {
        return result['deleteFiles'] as bool;
      }
      return null;
    });
  }

  Widget _buildTorrentStatsPanel(
    BuildContext context,
    DownloadTask task,
    DownloadProvider provider,
    SettingsProvider settings,
  ) {
    final isDark = settings.isDarkMode;
    final secClr = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final isRtl = L10n.isRtl(context);
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final amberClr = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;

    final seeds = provider.getTorrentSeeds(task.id);
    final peers = provider.getTorrentPeers(task.id);
    final isActive = task.status == DownloadStatus.downloading;
    final isSeeding =
        task.status == DownloadStatus.completed &&
        task.isTorrent &&
        task.seedingEnabled;

    // Current download speed (from task) and upload speed (from provider)
    final dlSpeed = task.speed;
    final ulSpeed = isSeeding
        ? task.speed
        : (task.isTorrent ? provider.getTorrentUploadSpeed(task.id) : 0.0);

    return GlassCard(
      borderRadius: 20,
      padding: const EdgeInsets.all(16),
      isDarkMode: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isRtl ? 'حالة اتصال التورنت' : 'TORRENT CONNECTION STATUS',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: secClr,
              fontSize: 10,
              letterSpacing: 1.0,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),

          // Speed row — download speed + upload speed
          if (isActive || isSeeding) ...[
            Row(
              children: [
                if (isActive)
                  Expanded(
                    child: _buildStatCell(
                      context,
                      icon: Icons.download_rounded,
                      color: blueClr,
                      label: isRtl ? 'سرعة التحميل' : 'DOWNLOAD',
                      value: '${formatBytes(dlSpeed)}/s',
                      textClr: textClr,
                      secClr: secClr,
                    ),
                  ),
                if (isActive || isSeeding)
                  Expanded(
                    child: _buildStatCell(
                      context,
                      icon: Icons.upload_rounded,
                      color: violetClr,
                      label: isRtl ? 'سرعة الرفع' : 'UPLOAD',
                      value: '${formatBytes(ulSpeed)}/s',
                      textClr: textClr,
                      secClr: secClr,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          // Overall progress bar for active downloads
          if (isActive && task.fileSize > 0) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isRtl ? 'التقدم الكلي' : 'OVERALL PROGRESS',
                  style: TextStyle(
                    color: secClr,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  task.progressPercentString,
                  style: TextStyle(
                    color: blueClr,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: task.progress,
                backgroundColor:
                    (isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder)
                        .withValues(alpha: 0.3),
                valueColor: AlwaysStoppedAnimation<Color>(blueClr),
                minHeight: 5,
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Seeds + Peers row
          Row(
            children: [
              Expanded(
                child: _buildStatCell(
                  context,
                  icon: Icons.upload_outlined,
                  color: greenClr,
                  label: isRtl ? 'المصادر النشطة' : 'SEEDS',
                  value: '$seeds',
                  textClr: textClr,
                  secClr: secClr,
                ),
              ),
              Expanded(
                child: _buildStatCell(
                  context,
                  icon: Icons.people_outline,
                  color: amberClr,
                  label: isRtl ? 'النظراء النشطين' : 'PEERS',
                  value: '$peers',
                  textClr: textClr,
                  secClr: secClr,
                ),
              ),
              Expanded(
                child: _buildStatCell(
                  context,
                  icon: Icons.storage_outlined,
                  color: secClr,
                  label: isRtl ? 'المنقول' : 'TRANSFERRED',
                  value: task.downloadedSizeFormatted,
                  textClr: textClr,
                  secClr: secClr,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatCell(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    required Color textClr,
    required Color secClr,
  }) {
    return Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: secClr,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              style: TextStyle(
                color: textClr,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Torrent Files Panel — reads actual file sizes from disk for accurate progress
// ---------------------------------------------------------------------------
class _TorrentFilesPanel extends StatefulWidget {
  final DownloadTask task;
  final DownloadProvider provider;
  final SettingsProvider settings;

  const _TorrentFilesPanel({
    required this.task,
    required this.provider,
    required this.settings,
  });

  @override
  State<_TorrentFilesPanel> createState() => _TorrentFilesPanelState();
}

class _TorrentFilesPanelState extends State<_TorrentFilesPanel>
    with HapticHelper {
  /// Actual bytes confirmed on disk for each file (parallel to torrentFiles list).
  List<int> _diskBytes = [];
  Timer? _refreshTimer;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
    _scheduleRefresh();
  }

  @override
  void didUpdateWidget(_TorrentFilesPanel old) {
    super.didUpdateWidget(old);
    // Re-read disk when the task's downloaded bytes change noticeably
    // (avoids redundant I/O on every minor provider notification).
    if (old.task.downloadedBytes != widget.task.downloadedBytes ||
        old.task.status != widget.task.status) {
      _refresh();
    }
    // Start/stop polling based on active status
    if (widget.task.status == DownloadStatus.downloading &&
        _refreshTimer == null) {
      _scheduleRefresh();
    } else if (widget.task.status != DownloadStatus.downloading) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  void _scheduleRefresh() {
    if (widget.task.status != DownloadStatus.downloading) return;
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refresh(),
    );
  }

  Future<void> _refresh() async {
    final bytes = await widget.provider.getTorrentFileActualBytes(
      widget.task.id,
    );
    if (mounted) {
      setState(() {
        _diskBytes = bytes;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// Returns the best-available downloaded byte count for file [index].
  /// Prefers the disk-verified value; falls back to the provider estimate.
  int _resolvedBytes(int index, int estimatedBytes) {
    if (_diskBytes.length > index) {
      final disk = _diskBytes[index];
      // If the file doesn't exist on disk yet (0 bytes) but we have a
      // proportional estimate, keep the estimate so the bar isn't blank.
      return disk > 0 ? disk : estimatedBytes;
    }
    return estimatedBytes;
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final provider = widget.provider;
    final settings = widget.settings;
    final files = task.torrentFiles!;

    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;
    final glassBorder = isDark
        ? AppTheme.glassBorder
        : AppTheme.lightGlassBorder;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final isDownloading = task.status == DownloadStatus.downloading;
    final isCompleted = task.status == DownloadStatus.completed;

    return Column(
      children: [
        GlassCard(
          borderRadius: 20,
          padding: const EdgeInsets.all(16),
          isDarkMode: isDark,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.folder_open_outlined, color: blueClr, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isRtl
                          ? 'ملفات التورنت المضمنة'
                          : 'TORRENT INCLUDED FILES',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: secClr,
                        fontSize: 10,
                        letterSpacing: 1.0,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // Disk-verify indicator
                  if (isDownloading)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.storage_rounded, size: 11, color: greenClr),
                        const SizedBox(width: 3),
                        Text(
                          isRtl ? 'تحقق فعلي' : 'DISK VERIFIED',
                          style: TextStyle(
                            color: greenClr,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (_loading)
                Center(
                  child: SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: blueClr,
                    ),
                  ),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: files.length,
                  separatorBuilder: (context, index) => Divider(
                    height: 16,
                    thickness: 0.3,
                    color: glassBorder.withValues(alpha: 0.4),
                  ),
                  itemBuilder: (context, index) {
                    final f = files[index];
                    final name = f['name'] as String? ?? 'unknown';
                    final length = (f['length'] as int?) ?? 0;
                    final selected = (f['selected'] as bool?) ?? true;
                    final estimatedBytes = (f['downloadedBytes'] as int?) ?? 0;
                    final speed = (f['speed'] as num?)?.toDouble() ?? 0.0;

                    // Use disk-verified bytes when available
                    final resolvedBytes = _resolvedBytes(index, estimatedBytes);
                    final diskVerified =
                        _diskBytes.length > index && _diskBytes[index] > 0;
                    final fileProgress = length > 0
                        ? (resolvedBytes / length).clamp(0.0, 1.0)
                        : 0.0;

                    // Show ✓ badge when file is fully on disk
                    final fileComplete = fileProgress >= 1.0;

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: Checkbox(
                            value: selected,
                            activeColor: blueClr,
                            side: BorderSide(color: glassBorder, width: 1.0),
                            onChanged: isCompleted
                                ? null
                                : (val) {
                                    if (val != null) {
                                      triggerHaptic(settings);
                                      final updatedFiles =
                                          List<Map<String, dynamic>>.from(
                                            files,
                                          );
                                      updatedFiles[index] = {
                                        ...f,
                                        'selected': val,
                                      };
                                      provider.updateTorrentTaskFiles(
                                        task.id,
                                        updatedFiles,
                                      );
                                    }
                                  },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          fileComplete
                              ? Icons.check_circle_outline_rounded
                              : Icons.insert_drive_file_outlined,
                          size: 16,
                          color: fileComplete
                              ? greenClr
                              : (selected ? textClr : secClr),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      name,
                                      style: TextStyle(
                                        color: selected ? textClr : secClr,
                                        fontSize: 12,
                                        fontWeight: selected
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        decoration: selected
                                            ? null
                                            : TextDecoration.lineThrough,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (selected) ...[
                                    const SizedBox(width: 8),
                                    _buildPrioritySelector(
                                      context: context,
                                      priority: f['priority'] as int? ?? 4,
                                      isDark: isDark,
                                      isRtl: isRtl,
                                      isCompleted: isCompleted,
                                      onChanged: (newPriority) {
                                        triggerHaptic(settings);
                                        final updatedFiles =
                                            List<Map<String, dynamic>>.from(
                                              files,
                                            );
                                        updatedFiles[index] = {
                                          ...f,
                                          'priority': newPriority,
                                        };
                                        provider.updateTorrentTaskFiles(
                                          task.id,
                                          updatedFiles,
                                        );
                                      },
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 6),
                              if (selected) ...[
                                Stack(
                                  children: [
                                    Container(
                                      height: 4,
                                      width: double.infinity,
                                      decoration: BoxDecoration(
                                        color: glassBorder.withValues(
                                          alpha: 0.3,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                    FractionallySizedBox(
                                      widthFactor: fileProgress,
                                      child: Container(
                                        height: 4,
                                        decoration: BoxDecoration(
                                          color: fileComplete
                                              ? greenClr
                                              : (isDownloading
                                                    ? blueClr
                                                    : secClr),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          '${formatBytes(resolvedBytes)} / ${formatBytes(length)}',
                                          style: TextStyle(
                                            color: secClr,
                                            fontSize: 10,
                                          ),
                                        ),
                                        if (diskVerified) ...[
                                          const SizedBox(width: 4),
                                          Icon(
                                            Icons.storage_rounded,
                                            size: 9,
                                            color: greenClr,
                                          ),
                                        ],
                                      ],
                                    ),
                                    if (speed > 0 && isDownloading)
                                      Text(
                                        '${formatBytes(speed)}/s',
                                        style: TextStyle(
                                          color: blueClr,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    Text(
                                      '${(fileProgress * 100).toStringAsFixed(1)}%',
                                      style: TextStyle(
                                        color: fileComplete
                                            ? greenClr
                                            : textClr,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ] else ...[
                                Text(
                                  isRtl ? 'تم تخطيه' : 'Skipped',
                                  style: TextStyle(
                                    color: secClr,
                                    fontSize: 10,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildPrioritySelector({
    required BuildContext context,
    required int priority,
    required bool isDark,
    required bool isRtl,
    required bool isCompleted,
    required ValueChanged<int> onChanged,
  }) {
    final Color priorityColor;
    final String label;
    switch (priority) {
      case 7:
        priorityColor = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
        label = isRtl ? 'عالية' : 'High';
        break;
      case 1:
        priorityColor = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
        label = isRtl ? 'منخفضة' : 'Low';
        break;
      case 4:
      default:
        priorityColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
        label = isRtl ? 'عادية' : 'Normal';
        break;
    }

    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: priorityColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: priorityColor.withValues(alpha: 0.3),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: priorityColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: priorityColor,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (!isCompleted) ...[
            const SizedBox(width: 2),
            Icon(
              Icons.arrow_drop_down,
              size: 12,
              color: priorityColor,
            ),
          ],
        ],
      ),
    );

    if (isCompleted) {
      return child;
    }

    return PopupMenuButton<int>(
      tooltip: isRtl ? 'تحديد الأولوية' : 'Set priority',
      padding: EdgeInsets.zero,
      onSelected: onChanged,
      child: child,
      itemBuilder: (context) => [
        PopupMenuItem<int>(
          value: 7,
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isRtl ? 'عالية' : 'High',
                style: TextStyle(
                  color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem<int>(
          value: 4,
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isRtl ? 'عادية' : 'Normal',
                style: TextStyle(
                  color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem<int>(
          value: 1,
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isRtl ? 'منخفضة' : 'Low',
                style: TextStyle(
                  color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
