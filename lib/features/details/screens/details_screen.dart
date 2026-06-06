import 'package:flutter/material.dart';
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
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../shared/widgets/glass_card.dart';

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
                  isRtl ? 'فقد الاتصال بالإشارة' : 'SIGNAL LOST OR DISCONNECTED',
                  style: TextStyle(
                    color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            }

            final task = provider.tasks[taskIndex];

            // Status colors
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
                          speedText: task.status == DownloadStatus.downloading
                              ? task.speedFormatted
                              : L10n.translateStatusName(context, task.status).toUpperCase(),
                          etaText: task.status == DownloadStatus.downloading
                              ? L10n.translateStatus(context, task.status, task.etaFormatted)
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
                              color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
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
                              color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
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
                              color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
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
                              color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                              isFilled: true,
                            ),
                          const SizedBox(width: 16),
                          NeonGlowButton(
                            onPressed: () {
                              triggerHaptic(settings);
                              provider.deleteTask(task.id);
                              ThemedSnackbar.show(
                                context,
                                message: isRtl ? 'تم حذف النقل بنجاح' : 'Transfer record deleted',
                                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                                icon: Icons.delete,
                                isDarkMode: isDark,
                              );
                              Navigator.pop(context);
                            },
                            text: L10n.of(context, 'delete_btn'),
                            icon: Icons.delete_outline,
                            color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),

                      // Connection Channels / Chunks Visualizer
                      _buildChannelsPanel(context, task, statusColor, settings),
                      const SizedBox(height: 20),

                      // Individual Speed and Seeding Controls Panel
                      _buildTaskBandwidthPanel(context, task, provider, settings),
                      const SizedBox(height: 20),

                      // Telemetry Speed History Graph
                      _buildSpeedGraphPanel(context, task, provider, settings),
                      const SizedBox(height: 20),

                      // File Metadata Panel
                      _buildMetadataPanel(context, task, settings),
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
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
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
            L10n.isRtl(context) ? 'مخطط سرعة النقل (تيليميتري)' : 'TELEMETRY SPEED CHART',
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
                    ? (L10n.isRtl(context) ? 'جاري تجميع البيانات...' : 'AWAITING TELEMETRY STREAMS...')
                    : (L10n.isRtl(context) ? 'محرك النقل غير نشط' : 'TRANSMISSION ENGINE INACTIVE'),
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

  Widget _buildChannelsPanel(
    BuildContext context,
    DownloadTask task,
    Color statusColor,
    SettingsProvider settings,
  ) {
    final isDark = settings.isDarkMode;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
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
                                    : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted),
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: task.status == DownloadStatus.downloading && isDark
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

  Widget _buildMetadataPanel(BuildContext context, DownloadTask task, SettingsProvider settings) {
    final isDark = settings.isDarkMode;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

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
          _buildMetaRow(context, label: L10n.of(context, 'details_filename'), value: task.fileName, settings: settings),
          _buildMetaRow(
            context,
            label: L10n.of(context, 'details_url'),
            value: task.url,
            isUrl: true,
            settings: settings,
          ),
          _buildMetaRow(context, label: L10n.of(context, 'details_path'), value: task.savePath, settings: settings),
          _buildMetaRow(
            context,
            label: L10n.of(context, 'details_local_file'),
            value: task.localFilePath,
            settings: settings,
          ),
          _buildMetaRow(context, label: L10n.of(context, 'details_size'), value: task.sizeFormatted, settings: settings),
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
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: 12,
              color: textClr,
              fontWeight: isUrl ? FontWeight.normal : FontWeight.bold,
            ),
            maxLines: isUrl ? 2 : 1,
            overflow: TextOverflow.ellipsis,
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
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
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
                    style: TextStyle(color: textClr, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hasLimit
                        ? '${task.speedLimitKbps} kbps (${(task.speedLimitKbps / 8).toStringAsFixed(1)} KB/s)'
                        : (isRtl ? 'غير محدود' : 'UNLIMITED SPEED'),
                    style: TextStyle(color: hasLimit ? blueClr : secClr, fontSize: 11, fontFamily: 'monospace'),
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
                          provider.updateTaskSpeedLimit(task.id, task.speedLimitKbps - 100);
                        },
                ),
                const SizedBox(width: 16),
                _buildSpeedStepButton(
                  context: context,
                  label: '+100 kbps',
                  isDark: isDark,
                  onPressed: () {
                    triggerHaptic(settings);
                    provider.updateTaskSpeedLimit(task.id, task.speedLimitKbps + 100);
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
                  isRtl ? 'إعدادات مشاركة التورنت (Seeding)' : 'TORRENT SEEDING INTERFACE',
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
                      isRtl ? 'تفعيل المشاركة (Seeding)' : 'SEEDING TRANSMISSION',
                      style: TextStyle(color: textClr, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      task.seedingEnabled
                          ? (isRtl ? 'نشط عند اكتمال التحميل' : 'ACTIVE ON COMPLETION')
                          : (isRtl ? 'غير نشط' : 'DISABLED'),
                      style: TextStyle(color: task.seedingEnabled ? violetClr : secClr, fontSize: 11),
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
                        style: TextStyle(color: textClr, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        task.seedingLimited
                            ? '${task.seedingLimitKbps} kbps (${(task.seedingLimitKbps / 8).toStringAsFixed(1)} KB/s)'
                            : (isRtl ? 'سرعة رفع قصوى' : 'UNLIMITED UPLOAD'),
                        style: TextStyle(color: task.seedingLimited ? violetClr : secClr, fontSize: 11, fontFamily: 'monospace'),
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
                              provider.updateTaskSeeding(task.id, limitKbps: task.seedingLimitKbps - 100);
                            },
                    ),
                    const SizedBox(width: 16),
                    _buildSpeedStepButton(
                      context: context,
                      label: '+100 kbps',
                      isDark: isDark,
                      onPressed: () {
                        triggerHaptic(settings);
                        provider.updateTaskSeeding(task.id, limitKbps: task.seedingLimitKbps + 100);
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
}
