import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/site_intelligence/site_intelligence_service.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/tracker_manager.dart';
import '../../../core/utils/constants.dart';
import '../../../core/utils/file_opener.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/intl_formatters.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/responsive.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/mixins/pausable_loop_animation.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../widgets/peer_panel.dart';
import '../widgets/torrent_advanced_settings_sheet.dart';
import '../widgets/torrent_files_panel.dart';
import '../widgets/torrent_health_indicator.dart';
import '../widgets/torrent_stats_dashboard.dart';
import '../widgets/tracker_panel.dart';

class DetailsScreen extends StatefulWidget {
  final String taskId;

  const DetailsScreen({super.key, required this.taskId});

  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen>
    with
        HapticHelper,
        TickerProviderStateMixin,
        WidgetsBindingObserver,
        PausableLoopAnimation<DetailsScreen> {
  late AnimationController _reveal;

  late AnimationController _pulse;

  final bool _graphExpanded = true;

  final Map<double, Animation<double>> _fadeAnimations = {};
  final Map<double, Animation<Offset>> _slideAnimations = {};

  @override
  AnimationController get loopController => _pulse;

  @override
  void initState() {
    super.initState();

    _reveal = AnimationController(vsync: this, duration: AppTheme.motionReveal)
      ..forward();

    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );

    startPausableLoop();
  }

  @override
  void dispose() {
    stopPausableLoop();

    _reveal.dispose();

    _pulse.dispose();

    super.dispose();
  }

  Widget _stagger(double start, Widget child) {
    final fadeAnim = _fadeAnimations.putIfAbsent(
      start,
      () => _reveal.drive(
        CurveTween(
          curve: Interval(
            start,
            (start + 0.5).clamp(0.0, 1.0),
            curve: AppTheme.motionCurve,
          ),
        ),
      ),
    );

    final slideAnim = _slideAnimations.putIfAbsent(
      start,
      () => _reveal.drive(
        Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).chain(
          CurveTween(
            curve: Interval(
              start,
              (start + 0.5).clamp(0.0, 1.0),
              curve: AppTheme.motionCurve,
            ),
          ),
        ),
      ),
    );

    return FadeTransition(
      opacity: fadeAnim,
      child: SlideTransition(
        position: slideAnim,
        child: child,
      ),
    );
  }

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
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                  fontSize: 16,
                ),
          ),
          leading: IconButton(
            icon: Icon(
              isRtl ? Icons.arrow_forward_ios : Icons.arrow_back_ios_new,
              size: 18,
            ),
            onPressed: () {
              triggerHaptic(settings);

              Navigator.pop(context);
            },
          ),
        ),
        body: Consumer<DownloadProvider>(
          builder: (context, provider, child) {
            final taskIndex = provider.tasks.indexWhere(
              (t) => t.id == widget.taskId,
            );

            if (taskIndex == -1) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      size: 48,
                      color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      isRtl
                          ? 'مهمة التنزيل غير موجودة'
                          : 'Download Task Not Found',
                      style: TextStyle(
                        color:
                            isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back),
                      label: Text(isRtl ? 'رجوع' : 'Go Back'),
                    ),
                  ],
                ),
              );
            }

            final task = provider.tasks[taskIndex];

            if (task.status == DownloadStatus.downloading) {
              if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
            } else {
              if (_pulse.isAnimating) _pulse.stop();
            }

            final isSeeding = task.status == DownloadStatus.completed &&
                task.isTorrent &&
                task.seedingEnabled;

            final isDownloadingTorrent =
                task.status == DownloadStatus.downloading && task.isTorrent;

            String speedTextInsideCircle;

            if (isDownloadingTorrent) {
              final ulSpeed = provider.getTorrentUploadSpeed(task.id);

              speedTextInsideCircle =
                  'DL: ${task.speedFormatted} | UL: ${formatBytes(ulSpeed)}/s';
            } else if (isSeeding) {
              speedTextInsideCircle = 'UL: ${task.speedFormatted}';
            } else {
              speedTextInsideCircle = task.status == DownloadStatus.downloading
                  ? task.speedFormatted
                  : L10n.translateStatusName(
                      context,
                      task.status,
                    ).toUpperCase();
            }

            final statusColor = DmxStatusColors.of(task.status, isDark);

            final isTwoColumn = isLandscape(context) || isTablet(context);

            return Directionality(
              textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
              child: SafeArea(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 12,
                  ),
                  child: isTwoColumn
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 5,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _stagger(
                                    0.0,
                                    Hero(
                                      tag: 'download_card_${widget.taskId}',
                                      createRectTween: (begin, end) =>
                                          RectTween(begin: begin, end: end),
                                      child: _TelemetryHero(
                                        task: task,
                                        statusColor: statusColor,
                                        speedText: speedTextInsideCircle,
                                        etaText: (task.status ==
                                                    DownloadStatus
                                                        .downloading ||
                                                isSeeding)
                                            ? L10n.translateStatus(
                                                context,
                                                task.status,
                                                task.etaFormatted,
                                              )
                                            : L10n.of(context,
                                                'details_inactive_eta'),
                                        pulse: _pulse,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  _stagger(
                                    0.1,
                                    _ActionRail(
                                      task: task,
                                      provider: provider,
                                      settings: settings,
                                      statusColor: statusColor,
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  if (task.isTorrent) ...[
                                    _stagger(
                                      0.2,
                                      _TorrentStatsPanel(
                                          task: task, provider: provider),
                                    ),
                                  ] else ...[
                                    _stagger(
                                      0.2,
                                      _ChannelsPanel(
                                        task: task,
                                        provider: provider,
                                        statusColor: statusColor,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 14),
                                  _stagger(
                                    0.3,
                                    _BandwidthPanel(
                                        task: task, provider: provider),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 6,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _stagger(
                                    0.4,
                                    Visibility(
                                      visible: _graphExpanded,
                                      maintainState: false,
                                      child: _SpeedGraphPanel(
                                        task: task,
                                        provider: provider,
                                      ),
                                    ),
                                  ),
                                  if (_graphExpanded)
                                    const SizedBox(height: 14),
                                  _stagger(
                                    0.5,
                                    _TorrentFilesPanel(
                                      task: task,
                                      provider: provider,
                                      settings: settings,
                                    ),
                                  ),
                                  if (task.isTorrent)
                                    const SizedBox(height: 14),
                                  _stagger(
                                    0.6,
                                    _MetadataPanel(
                                        task: task, provider: provider),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _stagger(
                              0.0,
                              Hero(
                                tag: 'download_card_${widget.taskId}',
                                createRectTween: (begin, end) =>
                                    RectTween(begin: begin, end: end),
                                child: _TelemetryHero(
                                  task: task,
                                  statusColor: statusColor,
                                  speedText: speedTextInsideCircle,
                                  etaText: (task.status ==
                                              DownloadStatus.downloading ||
                                          isSeeding)
                                      ? L10n.translateStatus(
                                          context,
                                          task.status,
                                          task.etaFormatted,
                                        )
                                      : L10n.of(
                                          context, 'details_inactive_eta'),
                                  pulse: _pulse,
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            _stagger(
                              0.1,
                              _ActionRail(
                                task: task,
                                provider: provider,
                                settings: settings,
                                statusColor: statusColor,
                              ),
                            ),
                            const SizedBox(height: 14),
                            if (task.isTorrent) ...[
                              _stagger(
                                0.2,
                                _TorrentStatsPanel(
                                    task: task, provider: provider),
                              ),
                            ] else ...[
                              _stagger(
                                0.2,
                                _ChannelsPanel(
                                  task: task,
                                  provider: provider,
                                  statusColor: statusColor,
                                ),
                              ),
                            ],
                            const SizedBox(height: 14),
                            _stagger(
                              0.3,
                              _BandwidthPanel(task: task, provider: provider),
                            ),
                            const SizedBox(height: 14),
                            _stagger(
                              0.4,
                              Visibility(
                                visible: _graphExpanded,
                                maintainState: false,
                                child: _SpeedGraphPanel(
                                  task: task,
                                  provider: provider,
                                ),
                              ),
                            ),
                            if (_graphExpanded) const SizedBox(height: 14),
                            _stagger(
                              0.5,
                              _TorrentFilesPanel(
                                task: task,
                                provider: provider,
                                settings: settings,
                              ),
                            ),
                            if (task.isTorrent) const SizedBox(height: 14),
                            _stagger(
                              0.6,
                              _MetadataPanel(task: task, provider: provider),
                            ),
                            const SizedBox(height: 24),
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
}

// ─────────────────────────────────────────────────────────────

// Telemetry Hero — the opening statement of the screen

// ─────────────────────────────────────────────────────────────

class _TelemetryHero extends StatelessWidget {
  final DownloadTask task;

  final Color statusColor;

  final String speedText;

  final String etaText;

  final AnimationController pulse;

  const _TelemetryHero({
    required this.task,
    required this.statusColor,
    required this.speedText,
    required this.etaText,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<SettingsProvider>(
      context,
    ).isDarkMode;

    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return DmxCardShell(
      accent: statusColor,
      radius: 20,
      showRail: false,
      child: Stack(
        children: [
          // ambient corner accent

          Positioned(
            top: 0,
            right: 0,
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(20),
              ),
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      statusColor.withValues(alpha: 0.10),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                // Progress ring

                RepaintBoundary(
                  key: const ValueKey('details_pulse_ring'),
                  child: AnimatedBuilder(
                    animation: pulse,
                    builder: (context, _) {
                      return SizedBox(
                        width: responsiveValue(context, 110),
                        height: responsiveValue(context, 110),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            RepaintBoundary(
                              child: CustomPaint(
                                size: Size(responsiveValue(context, 110),
                                    responsiveValue(context, 110)),
                                painter: _RingPainter(
                                  progress: task.progress,
                                  color: statusColor,
                                  glow: pulse.value,
                                  isDark: isDark,
                                ),
                              ),
                            ),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  task.progressPercentString,
                                  style: AppTheme.dataStyle(
                                    isDark: isDark,
                                    size: 20,
                                    weight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  task.isTorrent
                                      ? '${task.torrentFiles?.length ?? 0} FILES'
                                      : '${task.threadCount} CH',
                                  style: AppTheme.microLabel(
                                    isDark: isDark,
                                    color: statusColor,
                                    size: 8,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),

                const SizedBox(width: 20),

                // Readouts

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Status chip
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: statusColor.withValues(alpha: 0.35),
                            width: 0.8,
                          ),
                        ),
                        child: Text(
                          L10n.translateStatusName(
                            context,
                            task.status,
                          ).toUpperCase(),
                          style: AppTheme.microLabel(
                            isDark: isDark,
                            color: statusColor,
                            size: 9,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),

                      // Big speed readout
                      Text(
                        speedText,
                        style: AppTheme.dataStyle(
                          isDark: isDark,
                          size: 22,
                          weight: FontWeight.w800,
                          color: statusColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),

                      Text(
                        etaText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.dataStyle(
                          isDark: isDark,
                          size: 12,
                          weight: FontWeight.w600,
                          color: mutedClr,
                        ),
                      ),
                      const SizedBox(height: 6),

                      // Transferred / size

                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            task.downloadedSizeFormatted,
                            style: AppTheme.dataStyle(
                              isDark: isDark,
                              size: 13,
                              weight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            ' / ${task.sizeFormatted}',
                            style: AppTheme.dataStyle(
                              isDark: isDark,
                              size: 12,
                              weight: FontWeight.w500,
                              color: mutedClr,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;

  final Color color;

  final double glow;

  final bool isDark;

  _RingPainter({
    required this.progress,
    required this.color,
    required this.glow,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final radius = (size.width / 2 - 8).clamp(0.0, double.infinity);

    final track = Paint()
      ..color = (isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8;

    canvas.drawCircle(center, radius, track);

    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      fill,
    );

    // glow halo

    final halo = Paint()
      ..color = color.withValues(alpha: 0.15 + glow * 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      halo,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      (old.progress - progress).abs() > 0.001 ||
      (old.glow - glow).abs() > 0.01 ||
      old.color != color ||
      old.isDark != isDark;
}

// ─────────────────────────────────────────────────────────────

// Action Rail

// ─────────────────────────────────────────────────────────────

class _ActionRail extends StatelessWidget with HapticHelper {
  final DownloadTask task;

  final DownloadProvider provider;

  final SettingsProvider settings;

  final Color statusColor;

  const _ActionRail({
    required this.task,
    required this.provider,
    required this.settings,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = settings.isDarkMode;

    final isRtl = L10n.isRtl(context);

    final actions = <_ActionDef>[];

    final isPending = provider.isTaskOperationPending(task.id);

    if (isPending) {
      actions.add(
        _ActionDef(
          icon: task.status == DownloadStatus.downloading
              ? Icons.pause_rounded
              : Icons.play_arrow_rounded,
          label: isRtl ? 'جاري المعالجة...' : 'PROCESSING...',
          color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          filled: true,
          isLoading: true,
          onTap: () {},
        ),
      );
    } else if (task.status == DownloadStatus.downloading) {
      actions.add(
        _ActionDef(
          icon: Icons.pause_rounded,
          label: isRtl ? 'إيقاف' : 'PAUSE',
          color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
          filled: false,
          onTap: () {
            triggerHaptic(settings);

            provider.pauseTask(task.id);
          },
        ),
      );
    } else if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.queued) {
      actions.add(
        _ActionDef(
          icon: Icons.play_arrow_rounded,
          label: task.status == DownloadStatus.queued
              ? (isRtl ? 'بدء' : 'START')
              : (isRtl ? 'استئناف' : 'RESUME'),
          color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          filled: true,
          onTap: () {
            triggerHaptic(settings);

            provider.resumeTask(task.id);
          },
        ),
      );
    } else if (task.status == DownloadStatus.failed) {
      actions.add(
        _ActionDef(
          icon: Icons.refresh_rounded,
          label: isRtl ? 'إعادة' : 'RETRY',
          color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
          filled: true,
          onTap: () {
            triggerHaptic(settings);

            provider.retryTask(task.id);
          },
        ),
      );
    } else if (task.status == DownloadStatus.completed) {
      actions.add(
        _ActionDef(
          icon: Icons.folder_open_rounded,
          label: isRtl ? 'فتح الملف' : 'OPEN FILE',
          color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          filled: true,
          onTap: () {
            triggerHaptic(settings);

            openFile(context, task.localFilePath, settings);
          },
        ),
      );
    }

    actions.add(
      _ActionDef(
        icon: Icons.delete_outline_rounded,
        label: L10n.of(context, 'delete_btn'),
        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
        filled: false,
        onTap: () async {
          triggerHaptic(settings);

          final deleteFiles = await _showDeleteConfirmationDialog(
            context,
            task,
            settings,
          );

          if (deleteFiles != null) {
            unawaited(provider.deleteTask(task.id, deleteFiles: deleteFiles));

            if (context.mounted) {
              ThemedSnackbar.show(
                context,
                message: isRtl
                    ? 'تم حذف التنزيل بنجاح'
                    : 'Download deleted successfully',
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                icon: Icons.delete,
                isDarkMode: isDark,
              );

              Navigator.pop(context);
            }
          }
        },
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 430;

        if (narrow) {
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: actions
                .map((a) => SizedBox(
                      width: (constraints.maxWidth - 8) / 2,
                      child: _ActionButton(def: a),
                    ))
                .toList(),
          );
        }

        return Row(
          children: actions
              .map(
                (a) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _ActionButton(def: a),
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _ActionDef {
  final IconData icon;

  final String label;

  final Color color;

  final bool filled;

  final bool isLoading;

  final VoidCallback onTap;

  const _ActionDef({
    required this.icon,
    required this.label,
    required this.color,
    required this.filled,
    this.isLoading = false,
    required this.onTap,
  });
}

class _ActionButton extends StatefulWidget {
  final _ActionDef def;

  const _ActionButton({required this.def});

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final d = widget.def;

    return GestureDetector(
      onTapDown: d.isLoading ? null : (_) => setState(() => _pressed = true),
      onTapUp: d.isLoading ? null : (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: d.isLoading ? null : d.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: AppTheme.motionFast,
        curve: AppTheme.motionSpring,
        child: AnimatedContainer(
          duration: AppTheme.motionBase,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: d.filled ? d.color : d.color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: d.filled ? d.color : d.color.withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: d.filled
                ? [AppTheme.glow(d.color, alpha: 0.30, blur: 14)]
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                switchInCurve: Curves.easeOutBack,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, anim) => RotationTransition(
                  turns: Tween<double>(begin: 0.75, end: 1.0).animate(anim),
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: d.isLoading
                    ? SizedBox(
                        key: const ValueKey('action_spinner'),
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            d.filled ? AppTheme.inkOn(d.color) : d.color,
                          ),
                        ),
                      )
                    : Icon(
                        d.icon,
                        key: ValueKey(d.icon),
                        size: 20,
                        color: d.filled ? AppTheme.inkOn(d.color) : d.color,
                      ),
              ),
              const SizedBox(height: 4),
              Text(
                d.label,
                style: AppTheme.microLabel(
                  isDark: isDark,
                  color: d.filled ? AppTheme.inkOn(d.color) : d.color,
                  size: 8,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────

// Channels / Chunks Panel

// ─────────────────────────────────────────────────────────────

class _ChannelsPanel extends StatelessWidget with HapticHelper {
  final DownloadTask task;

  final DownloadProvider provider;

  final Color statusColor;

  const _ChannelsPanel({
    required this.task,
    required this.provider,
    required this.statusColor,
  });

  void _changeThreadCount(BuildContext context, int newCount) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    if (task.threadCount == newCount) return;

    final isRtl = L10n.isRtl(context);

    final isDark = settings.isDarkMode;

    if (task.downloadedBytes > 0) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
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
              color:
                  isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
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
        ),
      );
    } else {
      provider.updateTaskThreadCount(task.id, newCount);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);

    final isDark = settings.isDarkMode;

    final isBatterySaver = settings.batterySaverMode;

    final isRtl = L10n.isRtl(context);

    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    final isDualYoutube = task.hasMergedAudio || task.audioSize > 0;

    final videoDl = task.downloadedBytes;
    final videoSize = task.videoStreamSize > 0
        ? task.videoStreamSize
        : (task.fileSize > task.audioSize && task.audioSize > 0
            ? task.fileSize - task.audioSize
            : (task.audioSize <= 0 ? task.fileSize : 0));
    final videoProgress =
        videoSize > 0 ? (videoDl / videoSize).clamp(0.0, 1.0) : 0.0;

    final audioDl = task.audioDownloadedBytes > 0
        ? task.audioDownloadedBytes
        : (task.ytCounterpartDownloadedBytes ?? 0);
    final audioSize = task.audioSize;
    final audioProgress = audioSize > 0
        ? (audioDl / audioSize).clamp(0.0, 1.0)
        : task.audioProgressPercent;

    return DmxCardShell(
      accent: statusColor,
      showRail: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isDualYoutube) ...[
              Row(
                children: [
                  Icon(Icons.video_collection_outlined,
                      color: statusColor, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    isRtl
                        ? 'مسارات يوتيوب (فيديو + صوت)'
                        : 'YOUTUBE DUAL STREAMS',
                    style: AppTheme.microLabel(isDark: isDark, size: 10),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _buildStreamProgressBar(
                context,
                label: isRtl ? 'فيديو' : 'VIDEO',
                icon: Icons.videocam_outlined,
                downloaded: videoDl,
                total: videoSize,
                progress: videoProgress,
                statusColor:
                    isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                isDark: isDark,
                isRtl: isRtl,
                mutedClr: mutedClr,
              ),
              const SizedBox(height: 10),
              _buildStreamProgressBar(
                context,
                label: isRtl ? 'صوت' : 'AUDIO',
                icon: Icons.audiotrack_outlined,
                downloaded: audioDl,
                total: audioSize,
                progress: audioProgress,
                statusColor:
                    isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                isDark: isDark,
                isRtl: isRtl,
                mutedClr: mutedClr,
              ),
              const SizedBox(height: 14),
              Divider(
                height: 1,
                thickness: 0.4,
                color:
                    isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
              ),
              const SizedBox(height: 14),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  L10n.of(context, 'details_channels'),
                  style: AppTheme.microLabel(isDark: isDark, size: 10),
                ),
                Text(
                  '${task.chunks.length} ${isRtl ? 'قنوات' : 'CH'}',
                  style: AppTheme.dataStyle(
                    isDark: isDark,
                    size: 11,
                    color: statusColor,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Thread adjuster

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isRtl ? 'تعديل خيوط الاتصال' : 'ADJUST THREADS',
                      style: AppTheme.microLabel(isDark: isDark, size: 9),
                    ),
                  ],
                ),
                Row(
                  children: [
                    _StepBtn(
                      icon: Icons.remove_rounded,
                      color: statusColor,
                      onPressed: isBatterySaver
                          ? null
                          : () {
                              const list = kAvailableThreadOptions;

                              final curIdx = list.indexOf(task.threadCount);

                              if (curIdx > 0) {
                                _changeThreadCount(context, list[curIdx - 1]);
                              }
                            },
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: AppTheme.well(isDark: isDark, radius: 8),
                      child: Text(
                        '${task.threadCount}',
                        style: AppTheme.dataStyle(
                          isDark: isDark,
                          size: 14,
                          weight: FontWeight.w800,
                          color: statusColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _StepBtn(
                      icon: Icons.add_rounded,
                      color: statusColor,
                      onPressed: isBatterySaver
                          ? null
                          : () {
                              const list = kAvailableThreadOptions;

                              final curIdx = list.indexOf(task.threadCount);

                              if (curIdx != -1 && curIdx < list.length - 1) {
                                _changeThreadCount(context, list[curIdx + 1]);
                              }
                            },
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Channel bars

            Column(
              children: List.generate(task.chunks.length, (index) {
                final chunkProgress = task.chunks[index].clamp(0.0, 1.0);

                return Padding(
                  padding: const EdgeInsets.only(bottom: 10.0),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 44,
                        child: Text(
                          isRtl ? 'ق${index + 1}' : 'CH ${index + 1}',
                          style: AppTheme.microLabel(
                            isDark: isDark,
                            color: mutedClr,
                            size: 9,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Stack(
                          children: [
                            Container(
                              height: 6,
                              decoration:
                                  AppTheme.progressTrack(isDark: isDark),
                            ),
                            AnimatedFractionallySizedBox(
                              widthFactor: chunkProgress,
                              duration: const Duration(milliseconds: 400),
                              curve: AppTheme.motionCurve,
                              child: Container(
                                height: 6,
                                decoration: task.status ==
                                        DownloadStatus.completed
                                    ? BoxDecoration(
                                        color: statusColor,
                                        borderRadius: BorderRadius.circular(4),
                                      )
                                    : AppTheme.progressFill(statusColor),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 38,
                        child: Text(
                          '${(chunkProgress * 100).toStringAsFixed(0)}%',
                          textAlign: isRtl ? TextAlign.left : TextAlign.right,
                          style: AppTheme.dataStyle(
                            isDark: isDark,
                            size: 10,
                            color: task.status == DownloadStatus.downloading
                                ? statusColor
                                : mutedClr,
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
      ),
    );
  }

  Widget _buildStreamProgressBar(
    BuildContext context, {
    required String label,
    required IconData icon,
    required int downloaded,
    required int total,
    required double progress,
    required Color statusColor,
    required bool isDark,
    required bool isRtl,
    required Color mutedClr,
  }) {
    final percentStr = '${(progress * 100).toStringAsFixed(1)}%';
    final bytesStr = total > 0
        ? '${formatBytes(downloaded)} / ${formatBytes(total)}'
        : (downloaded > 0 ? formatBytes(downloaded) : '—');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 12, color: statusColor),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: AppTheme.microLabel(
                    isDark: isDark,
                    color: statusColor,
                    size: 9,
                  ),
                ),
              ],
            ),
            Text(
              bytesStr,
              style: AppTheme.dataStyle(
                isDark: isDark,
                size: 9,
                color: mutedClr,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Container(
                    height: 6,
                    decoration: AppTheme.progressTrack(isDark: isDark),
                  ),
                  AnimatedFractionallySizedBox(
                    widthFactor: progress,
                    duration: const Duration(milliseconds: 400),
                    curve: AppTheme.motionCurve,
                    child: Container(
                      height: 6,
                      decoration: progress >= 1.0
                          ? BoxDecoration(
                              color: statusColor,
                              borderRadius: BorderRadius.circular(4),
                            )
                          : AppTheme.progressFill(statusColor),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 42,
              child: Text(
                percentStr,
                textAlign: isRtl ? TextAlign.left : TextAlign.right,
                style: AppTheme.dataStyle(
                  isDark: isDark,
                  size: 10,
                  color: progress > 0 ? statusColor : mutedClr,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StepBtn extends StatefulWidget {
  final IconData icon;

  final Color color;

  final VoidCallback? onPressed;

  const _StepBtn({
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  @override
  State<_StepBtn> createState() => _StepBtnState();
}

class _StepBtnState extends State<_StepBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPressed == null;

    final color = disabled ? widget.color.withValues(alpha: 0.3) : widget.color;

    return Semantics(
      button: true,
      enabled: !disabled,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: Center(
          child: GestureDetector(
            onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
            onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
            onTapCancel:
                disabled ? null : () => setState(() => _pressed = false),
            onTap: widget.onPressed,
            child: AnimatedScale(
              scale: _pressed ? 0.85 : 1.0,
              duration: AppTheme.motionFast,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: color.withValues(alpha: 0.3),
                    width: 0.8,
                  ),
                ),
                child: Icon(widget.icon, size: 16, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────

// Speed Graph Panel

// ─────────────────────────────────────────────────────────────

class _SpeedGraphPanel extends StatefulWidget {
  final DownloadTask task;
  final DownloadProvider provider;

  const _SpeedGraphPanel({required this.task, required this.provider});

  @override
  State<_SpeedGraphPanel> createState() => _SpeedGraphPanelState();
}

class _SpeedGraphPanelState extends State<_SpeedGraphPanel> {
  DateTime _lastUpdateTime = DateTime.fromMillisecondsSinceEpoch(0);
  List<FlSpot> _cachedDownloadSpots = const [];
  List<FlSpot> _cachedUploadSpots = const [];
  int _cachedMaxLen = 1;

  void _updateSpotsIfNeeded() {
    final now = DateTime.now();
    if (now.difference(_lastUpdateTime) >= const Duration(milliseconds: 1000) ||
        _cachedDownloadSpots.isEmpty) {
      _lastUpdateTime = now;
      final speedHistory = widget.provider.getSpeedHistory(widget.task.id);
      final uploadHistory =
          widget.provider.getUploadSpeedHistory(widget.task.id);

      final List<FlSpot> dlSpots = List.generate(speedHistory.length, (i) {
        return FlSpot(i.toDouble(), speedHistory[i]);
      });
      if (dlSpots.length == 1) {
        dlSpots.add(FlSpot(1.0, dlSpots[0].y));
      }

      final List<FlSpot> ulSpots = List.generate(uploadHistory.length, (i) {
        return FlSpot(i.toDouble(), uploadHistory[i]);
      });
      if (ulSpots.length == 1) {
        ulSpots.add(FlSpot(1.0, ulSpots[0].y));
      }

      _cachedDownloadSpots = dlSpots;
      _cachedUploadSpots = ulSpots;
      _cachedMaxLen = math.max(
        dlSpots.length,
        ulSpots.isNotEmpty ? ulSpots.length : 1,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    _updateSpotsIfNeeded();
    final isDark = Provider.of<SettingsProvider>(context).isDarkMode;
    final primaryClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    final isDownloading = widget.task.status == DownloadStatus.downloading;
    final isSeeding = widget.task.status == DownloadStatus.completed &&
        widget.task.isTorrent &&
        widget.task.seedingEnabled;

    final showUploadSpeed =
        widget.task.isTorrent && (isDownloading || isSeeding);
    final uploadSpeed = showUploadSpeed
        ? widget.provider.getTorrentUploadSpeed(widget.task.id)
        : 0.0;

    final downloadSpots = _cachedDownloadSpots;
    final uploadSpots = _cachedUploadSpots;
    final maxLen = _cachedMaxLen;

    return DmxCardShell(
      showRail: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  L10n.isRtl(context) ? 'مخطط السرعة' : 'TRANSFER SPEED CHART',
                  style: AppTheme.microLabel(isDark: isDark, size: 10),
                ),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: primaryClr,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${L10n.isRtl(context) ? 'تحميل' : 'DL'}: ${formatBytes(widget.task.speed)}/s',
                      style: AppTheme.dataStyle(
                        isDark: isDark,
                        size: 10,
                        weight: FontWeight.w600,
                        color: primaryClr,
                      ),
                    ),
                    if (showUploadSpeed) ...[
                      const SizedBox(width: 10),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: violetClr,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${L10n.isRtl(context) ? 'رفع' : 'UL'}: ${formatBytes(uploadSpeed)}/s',
                        style: AppTheme.dataStyle(
                          isDark: isDark,
                          size: 10,
                          weight: FontWeight.w600,
                          color: violetClr,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            if ((!isDownloading && !isSeeding) || downloadSpots.isEmpty)
              Container(
                height: 120,
                alignment: Alignment.center,
                child: Text(
                  (isDownloading || isSeeding)
                      ? (L10n.isRtl(context)
                          ? 'جاري تجميع البيانات...'
                          : 'AWAITING SPEED DATA...')
                      : (L10n.isRtl(context)
                          ? 'محرك التنزيل غير نشط'
                          : 'TRANSFER ENGINE INACTIVE'),
                  style: AppTheme.microLabel(isDark: isDark, color: mutedClr),
                ),
              )
            else
              SizedBox(
                height: 120,
                child: LineChart(
                  LineChartData(
                    gridData: const FlGridData(show: false),
                    titlesData: FlTitlesData(
                      show: true,
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 18,
                          interval: math.max(1.0, (maxLen / 4).floorToDouble()),
                          getTitlesWidget: (value, meta) {
                            final idx = value.toInt();
                            if (idx < 0 || idx >= maxLen) {
                              return const SizedBox.shrink();
                            }
                            final secAgo = (maxLen - 1 - idx);
                            if (secAgo % 5 != 0 && idx != 0) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '${secAgo}s',
                                style: TextStyle(
                                  fontSize: 8,
                                  fontFamily: 'monospace',
                                  color: mutedClr,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      leftTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    lineTouchData: const LineTouchData(enabled: false),
                    minX: 0,
                    maxX: maxLen > 1 ? maxLen.toDouble() - 1 : 1.0,
                    lineBarsData: [
                      LineChartBarData(
                        spots: downloadSpots,
                        isCurved: true,
                        color: primaryClr,
                        barWidth: 2.0,
                        isStrokeCapRound: true,
                        dotData: const FlDotData(show: false),
                        belowBarData: BarAreaData(
                          show: true,
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              primaryClr.withValues(alpha: 0.25),
                              primaryClr.withValues(alpha: 0.0),
                            ],
                          ),
                        ),
                      ),
                      if (showUploadSpeed && uploadSpots.isNotEmpty)
                        LineChartBarData(
                          spots: uploadSpots,
                          isCurved: true,
                          color: violetClr,
                          barWidth: 2.0,
                          isStrokeCapRound: true,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                violetClr.withValues(alpha: 0.15),
                                violetClr.withValues(alpha: 0.0),
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
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────

// Bandwidth Panel (speed limit + seeding)

// ─────────────────────────────────────────────────────────────

class _BandwidthPanel extends StatefulWidget with HapticHelper {
  final DownloadTask task;

  final DownloadProvider provider;

  const _BandwidthPanel({required this.task, required this.provider});

  @override
  State<_BandwidthPanel> createState() => _BandwidthPanelState();
}

class _BandwidthPanelState extends State<_BandwidthPanel> with HapticHelper {
  int _lastSpeedLimitKbps = 500;

  DownloadTask get task => widget.task;

  DownloadProvider get provider => widget.provider;

  @override
  void initState() {
    super.initState();

    if (task.speedLimitKbps > 0) {
      _lastSpeedLimitKbps = task.speedLimitKbps;
    }
  }

  @override
  void didUpdateWidget(covariant _BandwidthPanel oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.task.speedLimitKbps > 0) {
      _lastSpeedLimitKbps = widget.task.speedLimitKbps;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);

    final isDark = settings.isDarkMode;

    final isRtl = L10n.isRtl(context);

    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;

    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    final hasLimit = task.speedLimitKbps > 0;

    return DmxCardShell(
      showRail: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.speed_rounded, color: blueClr, size: 16),
                const SizedBox(width: 8),
                Text(
                  isRtl ? 'التحكم في سرعة التحميل' : 'BANDWIDTH CONTROLS',
                  style: AppTheme.microLabel(isDark: isDark, size: 10),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isRtl ? 'حد التحميل الأقصى' : 'SPEED LIMIT',
                      style: AppTheme.microLabel(isDark: isDark, size: 9),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hasLimit
                          ? '${task.speedLimitKbps} kbps (${(task.speedLimitKbps / 8).toStringAsFixed(1)} KB/s)'
                          : (isRtl ? 'غير محدود' : 'UNLIMITED'),
                      style: AppTheme.dataStyle(
                        isDark: isDark,
                        size: 12,
                        color: hasLimit ? blueClr : mutedClr,
                      ),
                    ),
                  ],
                ),
                Switch(
                  value: hasLimit,
                  activeThumbColor: blueClr,
                  onChanged: (val) {
                    triggerHaptic(settings);

                    if (val) {
                      provider.updateTaskSpeedLimit(
                          task.id, _lastSpeedLimitKbps);
                    } else {
                      provider.updateTaskSpeedLimit(task.id, 0);
                    }
                  },
                ),
              ],
            ),
            if (hasLimit) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _SpeedStepButton(
                    label: '-100 kbps',
                    isDark: isDark,
                    onPressed: task.speedLimitKbps <= 100
                        ? null
                        : () {
                            triggerHaptic(settings);

                            final newVal = task.speedLimitKbps - 100;

                            _lastSpeedLimitKbps = newVal;

                            provider.updateTaskSpeedLimit(task.id, newVal);
                          },
                  ),
                  const SizedBox(width: 16),
                  _SpeedStepButton(
                    label: '+100 kbps',
                    isDark: isDark,
                    onPressed: () {
                      triggerHaptic(settings);

                      final newVal = task.speedLimitKbps + 100;

                      _lastSpeedLimitKbps = newVal;

                      provider.updateTaskSpeedLimit(task.id, newVal);
                    },
                  ),
                ],
              ),
            ],
            if (task.isTorrent) ...[
              const SizedBox(height: 16),
              Divider(
                color:
                    isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
                height: 1,
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(Icons.cloud_upload_outlined, color: violetClr, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    isRtl ? 'مشاركة التورنت (Seeding)' : 'TORRENT SEEDING',
                    style: AppTheme.microLabel(isDark: isDark, size: 10),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isRtl ? 'تفعيل المشاركة' : 'SEEDING',
                        style: AppTheme.microLabel(isDark: isDark, size: 9),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        task.seedingEnabled
                            ? (isRtl
                                ? 'نشط عند الاكتمال'
                                : 'ACTIVE ON COMPLETE')
                            : (isRtl ? 'غير نشط' : 'DISABLED'),
                        style: AppTheme.dataStyle(
                          isDark: isDark,
                          size: 12,
                          color: task.seedingEnabled ? violetClr : mutedClr,
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
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isRtl ? 'تقييد سرعة الرفع' : 'LIMIT UPLOAD',
                          style: AppTheme.microLabel(isDark: isDark, size: 9),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          task.seedingLimited
                              ? '${task.seedingLimitKbps} kbps'
                              : (isRtl ? 'غير محدود' : 'UNLIMITED'),
                          style: AppTheme.dataStyle(
                            isDark: isDark,
                            size: 12,
                            color: task.seedingLimited ? violetClr : mutedClr,
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
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _SpeedStepButton(
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
                      _SpeedStepButton(
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
      ),
    );
  }
}

class _SpeedStepButton extends StatelessWidget {
  final String label;

  final bool isDark;

  final VoidCallback? onPressed;

  const _SpeedStepButton({
    required this.label,
    required this.isDark,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
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

// ─────────────────────────────────────────────────────────────

// Torrent Stats Panel

// ─────────────────────────────────────────────────────────────

class _TorrentStatsPanel extends StatefulWidget {
  final DownloadTask task;
  final DownloadProvider provider;

  const _TorrentStatsPanel({required this.task, required this.provider});

  @override
  State<_TorrentStatsPanel> createState() => _TorrentStatsPanelState();
}

class _TorrentStatsPanelState extends State<_TorrentStatsPanel> {
  bool _showTrackers = false;
  bool _showPeers = false;

  late final TrackerManager _trackerManager;

  DownloadTask get task => widget.task;
  DownloadProvider get provider => widget.provider;

  @override
  void initState() {
    super.initState();
    // Created once and reused across rebuilds: constructing a fresh
    // TrackerManager in build() would drop user-added trackers on every
    // provider notify (the stats panel rebuilds while a download runs).
    _trackerManager = TrackerManager();
  }

  @override
  void dispose() {
    _trackerManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<SettingsProvider>(context).isDarkMode;
    final isRtl = L10n.isRtl(context);

    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final amberClr = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    final seeds = provider.getTorrentSeeds(task.id);
    final peers = provider.getTorrentPeers(task.id);

    final isActive = task.status == DownloadStatus.downloading;
    final isSeeding = task.status == DownloadStatus.completed &&
        task.isTorrent &&
        task.seedingEnabled;

    final dlSpeed = task.speed;
    final ulSpeed = isSeeding
        ? task.speed
        : (task.isTorrent ? provider.getTorrentUploadSpeed(task.id) : 0.0);

    final torrentId = int.tryParse(task.id) ?? 0;

    return DmxCardShell(
      accent: violetClr,
      showRail: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isRtl ? 'حالة اتصال التورنت' : 'TORRENT CONNECTION STATUS',
                  style: AppTheme.microLabel(isDark: isDark, size: 10),
                ),
                TorrentHealthIndicator(
                  seeds: seeds,
                  peers: peers,
                  availability: 1.0,
                  distributedCopies: 1.0,
                  downloadRate: dlSpeed,
                  isDark: isDark,
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (isActive || isSeeding) ...[
              Row(
                children: [
                  if (isActive)
                    Expanded(
                      child: _StatCell(
                        icon: Icons.download_rounded,
                        color: blueClr,
                        label: isRtl ? 'تحميل' : 'DOWN',
                        value: '${formatBytes(dlSpeed)}/s',
                        isDark: isDark,
                      ),
                    ),
                  if (isActive) const SizedBox(width: 10),
                  Expanded(
                    child: _StatCell(
                      icon: Icons.upload_rounded,
                      color: violetClr,
                      label: isRtl ? 'رفع' : 'UP',
                      value: '${formatBytes(ulSpeed)}/s',
                      isDark: isDark,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            if (isActive && task.fileSize > 0) ...[
              Stack(
                children: [
                  Container(
                    height: 6,
                    decoration: AppTheme.progressTrack(isDark: isDark),
                  ),
                  FractionallySizedBox(
                    widthFactor: task.progress.clamp(0.0, 1.0),
                    child: Container(
                      height: 6,
                      decoration: AppTheme.progressFill(blueClr),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            Row(
              children: [
                Expanded(
                  child: _StatCell(
                    icon: Icons.upload_outlined,
                    color: greenClr,
                    label: isRtl ? 'المصادر' : 'SEEDS',
                    value: '$seeds',
                    isDark: isDark,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatCell(
                    icon: Icons.people_outline,
                    color: amberClr,
                    label: isRtl ? 'النظراء' : 'PEERS',
                    value: '$peers',
                    isDark: isDark,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatCell(
                    icon: Icons.storage_outlined,
                    color: mutedClr,
                    label: isRtl ? 'المنقول' : 'XFER',
                    value: task.downloadedSizeFormatted,
                    isDark: isDark,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TorrentStatsDashboard(
              task: task,
              stats: null,
              isDark: isDark,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        setState(() => _showTrackers = !_showTrackers),
                    icon: Icon(
                      _showTrackers ? Icons.expand_less : Icons.add_link,
                      size: 14,
                      color: amberClr,
                    ),
                    label: Text(
                      _showTrackers
                          ? (isRtl ? 'إخفاء المتتبعات' : 'Hide Trackers')
                          : (isRtl ? 'إدارة المتتبعات' : 'Trackers Panel'),
                      style: TextStyle(fontSize: 11, color: amberClr),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: amberClr.withValues(alpha: 0.3)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => setState(() => _showPeers = !_showPeers),
                    icon: Icon(
                      _showPeers
                          ? Icons.expand_less
                          : Icons.people_alt_outlined,
                      size: 14,
                      color: blueClr,
                    ),
                    label: Text(
                      _showPeers
                          ? (isRtl ? 'إخفاء الأقران' : 'Hide Peers')
                          : (isRtl ? 'تفاصيل الأقران' : 'Peers Panel'),
                      style: TextStyle(fontSize: 11, color: blueClr),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: blueClr.withValues(alpha: 0.3)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () =>
                    TorrentAdvancedSettingsSheet.show(context, torrentId),
                icon:
                    const Icon(Icons.tune, size: 14, color: AppTheme.neonCyan),
                label: Text(
                  isRtl
                      ? 'إعدادات متقدمة (Web Seeds / Proxy / SSL)'
                      : 'Advanced Controls (Web Seeds / Proxy / SSL)',
                  style:
                      const TextStyle(fontSize: 11, color: AppTheme.neonCyan),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                      color: AppTheme.neonCyan.withValues(alpha: 0.3)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            if (_showTrackers) ...[
              const SizedBox(height: 12),
              TrackerPanel(
                torrentId: torrentId,
                trackerManager: _trackerManager,
              ),
            ],
            if (_showPeers) ...[
              const SizedBox(height: 12),
              PeerPanel(
                torrentId: torrentId,
                isDark: isDark,
                peers: const [],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  final IconData icon;

  final Color color;

  final String label;

  final String value;

  final bool isDark;

  const _StatCell({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: AppTheme.well(isDark: isDark, radius: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 5),
              Text(label, style: AppTheme.microLabel(isDark: isDark, size: 8)),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: AppTheme.dataStyle(
              isDark: isDark,
              size: 13,
              weight: FontWeight.w800,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────

// Torrent Files Panel (disk-verified progress)

// ─────────────────────────────────────────────────────────────

class _TorrentFilesPanel extends StatelessWidget with HapticHelper {
  final DownloadTask task;
  final DownloadProvider provider;
  final SettingsProvider settings;
  const _TorrentFilesPanel({
    required this.task,
    required this.provider,
    required this.settings,
  });

  Future<void> _deleteSingleTorrentFile(
    BuildContext context,
    int fileIndex,
    String fileName,
  ) async {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
        title: Text(
          isRtl ? 'حذف الملف؟' : 'Delete File?',
          style: TextStyle(
            color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
          ),
        ),
        content: Text(
          isRtl
              ? 'هل تريد حذف "$fileName" من وحدة التخزين وإلغاء تحميلة؟'
              : 'Are you sure you want to delete "$fileName" from storage and stop downloading it?',
          style: TextStyle(
            color:
                isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isRtl ? 'إلغاء' : 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.neonRed),
            child: Text(isRtl ? 'حذف' : 'Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final relPath = task.torrentFiles![fileIndex]['name'] as String? ?? '';
      if (relPath.isNotEmpty) {
        final normalizedSave = p.normalize(p.absolute(task.savePath));
        final fullPath = p.normalize(p.absolute(task.savePath, relPath));
        if (!p.isWithin(normalizedSave, fullPath) &&
            !p.equals(fullPath, normalizedSave)) {
          debugPrint(
            '[Security] _deleteSingleTorrentFile: blocked path traversal '
            'attempt. relPath="$relPath", resolved="$fullPath", '
            'savePath="$normalizedSave"',
          );
          if (context.mounted) {
            final isRtlLocal = L10n.isRtl(context);
            ThemedSnackbar.show(
              context,
              message: isRtlLocal
                  ? 'مسار الملف غير صالح — رُفض الحذف'
                  : 'Invalid file path — deletion rejected',
              color: AppTheme.neonRed,
              icon: Icons.warning_amber_rounded,
              isDarkMode: isDark,
            );
          }
          return;
        }
        final file = File(fullPath);
        if (await file.exists()) {
          await file.delete();
        }
      }
      final updatedFiles = List<Map<String, dynamic>>.from(
        task.torrentFiles!,
      );
      updatedFiles[fileIndex] = {
        ...updatedFiles[fileIndex],
        'selected': false,
        'priority': 0,
        'downloadedBytes': 0,
      };
      await provider.updateTorrentTaskFiles(
        task.id,
        updatedFiles,
      );
      if (context.mounted) {
        ThemedSnackbar.show(
          context,
          message: isRtl ? 'تم حذف الملف' : 'File deleted from disk',
          color: AppTheme.neonRed,
          icon: Icons.delete_forever_outlined,
          isDarkMode: isDark,
        );
      }
    } catch (e) {
      debugPrint('Failed to delete single torrent file: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Selector<DownloadProvider, List<Map<String, dynamic>>?>(
      selector: (_, p) =>
          p.taskById(task.id)?.torrentFiles ?? task.torrentFiles,
      shouldRebuild: (prev, next) {
        if (identical(prev, next)) return false;
        if (prev == null || next == null) return prev != next;
        if (prev.length != next.length) return true;
        for (int i = 0; i < prev.length; i++) {
          final p = prev[i];
          final n = next[i];
          // FIX: Added 'length' and 'name' to the diff so that
          // metadata-fetched size changes and file renames trigger
          // a UI rebuild. Previously, only downloadedBytes/progress/
          // selected/priority/progressEstimated were checked, which
          // meant size changes after metadata fetch were silently
          // ignored by the Selector.
          if (p['downloadedBytes'] != n['downloadedBytes'] ||
              p['progressEstimated'] != n['progressEstimated'] ||
              p['progress'] != n['progress'] ||
              p['selected'] != n['selected'] ||
              p['priority'] != n['priority'] ||
              p['length'] != n['length'] ||
              p['name'] != n['name']) {
            return true;
          }
        }
        return false;
      },
      builder: (context, dynamicTorrentFiles, _) {
        final currentTask = provider.taskById(task.id) ?? task;
        if (!currentTask.isTorrent ||
            dynamicTorrentFiles == null ||
            dynamicTorrentFiles.isEmpty) {
          return const SizedBox.shrink();
        }
        final files = dynamicTorrentFiles;
        final isDark = settings.isDarkMode;
        final isRtl = L10n.isRtl(context);
        final isDownloading = currentTask.status == DownloadStatus.downloading;
        return TorrentFilesPanel(
          torrentFiles: files,
          isDark: isDark,
          isRtl: isRtl,
          isDownloading: isDownloading,
          onSelectAll: () {
            triggerHaptic(settings);
            final updatedFiles = List<Map<String, dynamic>>.from(files);
            for (var i = 0; i < updatedFiles.length; i++) {
              updatedFiles[i] = {
                ...updatedFiles[i],
                'selected': true,
                'priority': 4,
              };
            }
            unawaited(
              provider
                  .updateTorrentTaskFiles(currentTask.id, updatedFiles)
                  .catchError((e) {
                LoggingService.logger('DetailsScreen').warning(
                  '[DetailsScreen] selecting all torrent files failed',
                  e,
                );
              }),
            );
          },
          onDeselectAll: () {
            triggerHaptic(settings);
            final updatedFiles = List<Map<String, dynamic>>.from(files);
            for (var i = 0; i < updatedFiles.length; i++) {
              updatedFiles[i] = {
                ...updatedFiles[i],
                'selected': false,
                'priority': 0,
              };
            }
            unawaited(
              provider
                  .updateTorrentTaskFiles(currentTask.id, updatedFiles)
                  .catchError((e) {
                LoggingService.logger('DetailsScreen').warning(
                  '[DetailsScreen] deselecting all torrent files failed',
                  e,
                );
              }),
            );
          },
          onFileToggle: (index, val) {
            triggerHaptic(settings);
            final updatedFiles = List<Map<String, dynamic>>.from(files);
            updatedFiles[index] = {
              ...files[index],
              'selected': val,
              'priority': val ? 4 : 0,
            };
            provider.updateTorrentTaskFiles(currentTask.id, updatedFiles);
          },
          onPriorityChanged: (index, newPriority) {
            triggerHaptic(settings);
            final updatedFiles = List<Map<String, dynamic>>.from(files);
            updatedFiles[index] = {
              ...files[index],
              'priority': newPriority,
            };
            provider.updateTorrentTaskFiles(currentTask.id, updatedFiles);
          },
          onDeleteFile: (index, name) {
            triggerHaptic(settings);
            _deleteSingleTorrentFile(context, index, name);
          },
        );
      },
    );
  }
}
// ─────────────────────────────────────────────────────────────

// Metadata Spec Sheet

// ─────────────────────────────────────────────────────────────

class _MetadataPanel extends StatelessWidget with HapticHelper {
  final DownloadTask task;

  final DownloadProvider provider;

  const _MetadataPanel({required this.task, required this.provider});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);

    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

    return DmxCardShell(
      showRail: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              L10n.of(context, 'details_metadata'),
              style: AppTheme.microLabel(isDark: isDark, size: 10),
            ),
            const SizedBox(height: 14),
            if (task.siteDisplayName != null)
              _MetaRow(
                label: isRtl ? 'الموقع' : 'SITE',
                value:
                    '${task.siteDisplayName} (${task.siteType?.replaceAll(RegExp(r'(?=[A-Z])'), ' ').toUpperCase() ?? "UNKNOWN"})',
                isDark: isDark,
              ),
            if (task.contentHint != null)
              _MetaRow(
                label: isRtl ? 'نوع المحتوى' : 'CONTENT HINT',
                value: task.contentHint!
                    .replaceAll(RegExp(r'(?=[A-Z])'), ' ')
                    .toUpperCase(),
                isDark: isDark,
              ),
            _MetaRow(
              label: L10n.of(context, 'details_filename'),
              value: task.fileName,
              isDark: isDark,
            ),
            _MetaRow(
              label: L10n.of(context, 'details_url'),
              value: task.url,
              isDark: isDark,
              isUrl: true,
              onCopy: () {
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
              onEdit: () =>
                  _showUpdateUrlDialog(context, task, provider, settings),
            ),
            if (task.mirrorUrls != null && task.mirrorUrls!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      L10n.isRtl(context)
                          ? 'رابط المرآة النشط'
                          : 'ACTIVE MIRROR',
                      style: AppTheme.microLabel(isDark: isDark, size: 8),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            task.url,
                            style: AppTheme.dataStyle(
                              isDark: isDark,
                              size: 12,
                              weight: FontWeight.w500,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Tooltip(
                          message: task.mirrorUrls!.join('\n'),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: (isDark
                                      ? AppTheme.neonBlue
                                      : AppTheme.lightNeonBlue)
                                  .withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: isDark
                                      ? AppTheme.neonBlue
                                      : AppTheme.lightNeonBlue),
                            ),
                            child: Text(
                              '${task.mirrorUrls!.length} mirrors',
                              style: TextStyle(
                                color: isDark
                                    ? AppTheme.neonBlue
                                    : AppTheme.lightNeonBlue,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            if (task.downloadPageUrl != null &&
                task.downloadPageUrl!.isNotEmpty)
              _MetaRow(
                label: L10n.isRtl(context)
                    ? 'صفحة التنزيل الأصلية'
                    : 'ORIGIN DOWNLOAD PAGE',
                value: task.downloadPageUrl!,
                isDark: isDark,
                isUrl: true,
                onCopy: () {
                  Clipboard.setData(ClipboardData(text: task.downloadPageUrl!));

                  ThemedSnackbar.show(
                    context,
                    message: L10n.isRtl(context)
                        ? 'تم نسخ رابط الصفحة'
                        : 'Page URL copied to clipboard',
                    color:
                        isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                    icon: Icons.check_circle_outline,
                    isDarkMode: isDark,
                  );
                },
                onOpen: () {
                  provider.openUrlInBrowser(task.downloadPageUrl!);

                  Navigator.pop(context);
                },
              ),
            _MetaRow(
              label: L10n.of(context, 'details_path'),
              value: task.savePath,
              isDark: isDark,
            ),
            _MetaRow(
              label: L10n.of(context, 'details_local_file'),
              value: task.localFilePath,
              isDark: isDark,
            ),
            _MetaRow(
              label: L10n.of(context, 'details_size'),
              value: task.sizeFormatted,
              isDark: isDark,
            ),
            _MetaRow(
              label: L10n.of(context, 'details_transferred'),
              value: task.downloadedSizeFormatted,
              isDark: isDark,
            ),
            _MetaRow(
              label: L10n.of(context, 'details_category'),
              value:
                  L10n.translateCategory(context, task.category).toUpperCase(),
              isDark: isDark,
            ),
            if (task.statusMessage != null && task.statusMessage!.isNotEmpty)
              _MetaRow(
                label: L10n.of(context, 'details_status'),
                value: task.statusMessage!,
                isDark: isDark,
              ),
            if (task.errorMessage != null)
              _MetaRow(
                label: L10n.of(context, 'details_error'),
                value: _translateErrorMessage(context, task.errorMessage!),
                isDark: isDark,
                onCopy: () {
                  Clipboard.setData(ClipboardData(text: task.errorMessage!));

                  ThemedSnackbar.show(
                    context,
                    message: L10n.isRtl(context)
                        ? 'تم نسخ رسالة الخطأ'
                        : 'Error message copied to clipboard',
                    color:
                        isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                    icon: Icons.check_circle_outline,
                    isDarkMode: isDark,
                  );
                },
              ),
            if (task.isTorrent) ...[
              _MetaRow(
                label: isRtl ? 'بروتوكول التورنت' : 'BITTORRENT PROTOCOL',
                value: (task.url.contains('urn:btmh') ||
                        (task.url.contains('urn:btih') &&
                            task.url.contains('urn:btmh')))
                    ? 'BitTorrent v2 (BEP 52 / Hybrid)'
                    : 'BitTorrent v1 / v2 Compatible',
                isDark: isDark,
              ),
            ],
            if (task.mergedAudioUrl != null &&
                task.mergedAudioUrl!.isNotEmpty) ...[
              _MetaRow(
                label: L10n.isRtl(context) ? 'رابط الصوت' : 'AUDIO URL',
                value: task.mergedAudioUrl!,
                isDark: isDark,
                isUrl: true,
                onCopy: () {
                  Clipboard.setData(ClipboardData(text: task.mergedAudioUrl!));

                  ThemedSnackbar.show(
                    context,
                    message: L10n.isRtl(context)
                        ? 'تم نسخ رابط الصوت'
                        : 'Audio URL copied to clipboard',
                    color:
                        isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                    icon: Icons.check_circle_outline,
                    isDarkMode: isDark,
                  );
                },
              ),
              if (task.audioSize > 0)
                _MetaRow(
                  label: L10n.isRtl(context) ? 'حجم الصوت' : 'AUDIO SIZE',
                  value: task.audioSizeFormatted,
                  isDark: isDark,
                ),
            ],
            if (task.status == DownloadStatus.completed &&
                task.completedAt != null)
              _MetaRow(
                label: L10n.isRtl(context) ? 'وقت الاكتمال' : 'COMPLETION TIME',
                value: formatLocalizedDateTime(context, task.completedAt!),
                isDark: isDark,
              ),
            _MetaRow(
              label: L10n.isRtl(context) ? 'الوقت المنقضي' : 'ELAPSED TIME',
              value: task.elapsedFormatted,
              isDark: isDark,
            ),
            if (task.expectedSha256 != null && task.expectedSha256!.isNotEmpty)
              _MetaRow(
                label: L10n.isRtl(context)
                    ? 'المجموع الاختباري'
                    : 'CHECKSUM (SHA-256)',
                value:
                    '${task.expectedSha256!.substring(0, task.expectedSha256!.length > 16 ? 16 : task.expectedSha256!.length)}...',
                isDark: isDark,
                onCopy: () {
                  Clipboard.setData(ClipboardData(text: task.expectedSha256!));

                  ThemedSnackbar.show(
                    context,
                    message: L10n.isRtl(context)
                        ? 'تم نسخ المجموع الاختباري'
                        : 'Checksum copied to clipboard',
                    color:
                        isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                    icon: Icons.check_circle_outline,
                    isDarkMode: isDark,
                  );
                },
              ),
            _MetaRow(
              label: L10n.of(context, 'details_established'),
              value: formatLocalizedDateTime(context, task.createdAt),
              isDark: isDark,
            ),
            Builder(builder: (context) {
              final reliability = SiteIntelligenceService()
                  .getReliability(Uri.tryParse(task.url)?.host ?? '');
              if (reliability == null) return const SizedBox.shrink();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  Text(
                    isRtl ? 'موثوقية الموقع' : 'SITE RELIABILITY',
                    style: AppTheme.microLabel(isDark: isDark, size: 8),
                  ),
                  const SizedBox(height: 8),
                  _MetaRow(
                    label: isRtl ? 'نسبة النجاح' : 'Success Rate',
                    value:
                        '${reliability.score}% (${reliability.successes}/${reliability.totalAttempts} attempts)',
                    isDark: isDark,
                  ),
                  if (reliability.averageSpeedMbps > 0)
                    _MetaRow(
                      label: isRtl ? 'متوسط السرعة' : 'Avg Speed',
                      value:
                          '${reliability.averageSpeedMbps.toStringAsFixed(1)} Mbps',
                      isDark: isDark,
                    ),
                ],
              );
            }),
            Builder(builder: (context) {
              final provider = context.read<DownloadProvider>();

              final metrics = provider.getMetrics(task.id);

              if (metrics == null) return const SizedBox.shrink();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  Text(
                    'PERFORMANCE',
                    style: AppTheme.microLabel(isDark: isDark, size: 8),
                  ),
                  const SizedBox(height: 8),
                  _MetaRow(
                    label: 'Peak Speed',
                    value: '${formatBytes(metrics.peakSpeedBps.toDouble())}/s',
                    isDark: isDark,
                  ),
                  _MetaRow(
                    label: 'TTFB',
                    value:
                        '${formatLocalizedNumber(context, metrics.timeToFirstByteMs)}ms',
                    isDark: isDark,
                  ),
                  if (metrics.resumed)
                    _MetaRow(
                      label: 'Resumed',
                      value:
                          '${formatBytes(metrics.resumeBytesSaved.toDouble())} saved',
                      isDark: isDark,
                    ),
                  if (metrics.checksumVerified)
                    _MetaRow(
                      label: 'Checksum',
                      value: metrics.checksumPassed ? 'PASS ✓' : 'FAIL ✗',
                      isDark: isDark,
                      isLast: true,
                    ),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }

  String _translateErrorMessage(BuildContext context, String err) {
    if (!L10n.isRtl(context)) return err;

    if (err.contains('Waiting for WiFi')) return 'في انتظار اتصال الواي فاي';

    if (err.contains('Transfer cancelled')) return 'تم إلغاء النقل';

    return err;
  }

  Future<void> _showUpdateUrlDialog(
    BuildContext context,
    DownloadTask task,
    DownloadProvider provider,
    SettingsProvider settings,
  ) async {
    final isDark = settings.isDarkMode;

    final isRtl = L10n.isRtl(context);

    final textController = TextEditingController(text: task.url);
    final hasAudio =
        task.mergedAudioUrl != null && task.mergedAudioUrl!.isNotEmpty;
    final audioTextController =
        hasAudio ? TextEditingController(text: task.mergedAudioUrl) : null;

    try {
      await showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
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
                maxLines: hasAudio ? 2 : 3,
                style: TextStyle(
                  color:
                      isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
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
                  hintText: hasAudio ? 'Video URL' : null,
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
              if (hasAudio && audioTextController != null) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: audioTextController,
                  maxLines: 2,
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
                    hintText: 'Audio Stream URL (Optional)',
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
                        color: (isDark
                                ? AppTheme.neonBlue
                                : AppTheme.lightNeonBlue)
                            .withValues(alpha: 0.5),
                        width: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                triggerHaptic(settings);

                Navigator.pop(dialogContext);
              },
              child: Text(
                L10n.of(dialogContext, 'cancel_btn'),
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
                final newAudio = audioTextController?.text.trim();

                if (newUrl.isEmpty) return;

                Navigator.pop(dialogContext);

                try {
                  await provider.updateTaskUrl(
                    task.id,
                    newUrl,
                    newAudioUrl: (newAudio != null && newAudio.isNotEmpty)
                        ? newAudio
                        : null,
                  );

                  if (context.mounted) {
                    ThemedSnackbar.show(
                      context,
                      message: isRtl
                          ? 'تم تحديث الرابط بنجاح. يمكنك استئناف التحميل الآن.'
                          : 'Link updated successfully. You can resume download now.',
                      color:
                          isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
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
        ),
      );
    } finally {
      textController.dispose();
    }
  }
}

class _MetaRow extends StatelessWidget {
  final String label;

  final String value;

  final bool isDark;

  final bool isUrl;

  final bool isLast;

  final VoidCallback? onCopy;

  final VoidCallback? onEdit;

  final VoidCallback? onOpen;

  const _MetaRow({
    required this.label,
    required this.value,
    required this.isDark,
    this.isUrl = false,
    this.isLast = false,
    this.onCopy,
    this.onEdit,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTheme.microLabel(isDark: isDark, size: 8)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  value,
                  style: AppTheme.dataStyle(
                    isDark: isDark,
                    size: 12,
                    weight: isUrl ? FontWeight.w500 : FontWeight.w700,
                  ),
                  maxLines: isUrl ? 2 : 1,
                ),
              ),
              if (onEdit != null) ...[
                const SizedBox(width: 6),
                _MetaAction(
                  icon: Icons.edit_outlined,
                  color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                  onTap: onEdit!,
                ),
              ],
              if (onCopy != null) ...[
                const SizedBox(width: 6),
                _MetaAction(
                  icon: Icons.copy_rounded,
                  color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                  onTap: onCopy!,
                ),
              ],
              if (onOpen != null) ...[
                const SizedBox(width: 6),
                _MetaAction(
                  icon: Icons.open_in_new_rounded,
                  color:
                      isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                  onTap: onOpen!,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _MetaAction extends StatefulWidget {
  final IconData icon;

  final Color color;

  final VoidCallback onTap;

  const _MetaAction({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  State<_MetaAction> createState() => _MetaActionState();
}

class _MetaActionState extends State<_MetaAction> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.8 : 1.0,
        duration: AppTheme.motionFast,
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: widget.color.withValues(alpha: 0.25),
              width: 0.7,
            ),
          ),
          child: Icon(widget.icon, size: 13, color: widget.color),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────

// Delete Confirmation Dialog

// ─────────────────────────────────────────────────────────────

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
                  color:
                      isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
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
                          activeColor:
                              isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                          side: BorderSide(
                            color: isDark
                                ? AppTheme.glassBorder
                                : AppTheme.lightGlassBorder,
                            width: 1.0,
                          ),
                          onChanged: (val) {
                            if (val != null) {
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
                            setState(() {
                              deleteFiles = !deleteFiles;
                            });
                          },
                          child: Text(
                            L10n.of(context, 'delete_files_label'),
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
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
                      color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
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
