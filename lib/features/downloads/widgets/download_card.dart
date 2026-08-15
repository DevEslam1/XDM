import 'dart:async';
import 'dart:io';
import 'package:dmx/shared/mixins/pausable_loop_animation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/download_engine.dart';
import '../../../core/services/performance_monitor.dart';
import '../../../core/services/power_monitor.dart';
import '../../../core/services/torrent_service.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/intl_formatters.dart';
import '../../../core/utils/responsive.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/file_opener.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/accessibility/xdm_semantics.dart';
import '../../../core/services/protocol_cache.dart';
import '../../settings/provider/settings_provider.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../details/screens/details_screen.dart';
import 'channel_progress_painter.dart';
import 'filter_chips_bar.dart';

import '../../../core/services/undo_service.dart';

/// Adaptive download card. Detects the download kind and renders a
/// purpose-built variant:
///   • Torrent / magnet  -> _TorrentCard  (seeds/peers, per-file %, seeding)
///   • Media / playlist  -> _MediaCard    (quality badge, audio track, merge)
///   • Single file       -> _FileCard     (chunked multi-thread progress)
///
/// Every variant exposes the same telemetry strip:
///   DOWNLOADED / TOTAL SIZE / ELAPSED / TIME REMAINING / SPEED
/// plus a chunked progress bar and the total percentage readout.
class DownloadCard extends StatelessWidget with HapticHelper {
  final DownloadTask task;
  final bool compact;
  final bool showDragHandle;
  final int? index;

  const DownloadCard({
    super.key,
    required this.task,
    this.compact = false,
    this.showDragHandle = false,
    this.index,
  });

  @override
  Widget build(BuildContext context) {
    final isSelectionMode =
        context.select((DownloadProvider p) => p.isSelectionMode);
    final provider = context.read<DownloadProvider>();

    final statusLabel = task.status.name;
    final semanticLabel = '${task.fileName}, status: $statusLabel, '
        '${(task.progress * 100).toStringAsFixed(0)}% downloaded, '
        '${task.speedFormatted}';

    final Widget cardWidget = RepaintBoundary(
      child: task.isTorrent
          ? _TorrentCard(
              task: task,
              compact: compact,
            )
          : (task.youtubeQualityPreset != null || task.mergedAudioUrl != null)
              ? _MediaCard(
                  task: task,
                  compact: compact,
                )
              : _FileCard(
                  task: task,
                  compact: compact,
                ),
    );

    final Widget interactiveCard = isSelectionMode
        ? cardWidget
        : Dismissible(
            key: ValueKey('dismiss_${task.id}'),
            direction: DismissDirection.horizontal,
            background: Container(
              alignment: AlignmentDirectional.centerStart,
              padding: const EdgeInsetsDirectional.only(start: 20),
              decoration: BoxDecoration(
                color: AppTheme.neonGreen.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                task.status == DownloadStatus.paused
                    ? Icons.play_arrow_rounded
                    : (task.status == DownloadStatus.failed
                        ? Icons.refresh_rounded
                        : Icons.folder_open_rounded),
                color: AppTheme.neonGreen,
              ),
            ),
            secondaryBackground: Container(
              alignment: AlignmentDirectional.centerEnd,
              padding: const EdgeInsetsDirectional.only(end: 20),
              decoration: BoxDecoration(
                color: AppTheme.neonRed.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.delete_outline_rounded,
                  color: AppTheme.neonRed),
            ),
            confirmDismiss: (direction) async {
              runHaptic(context.read<SettingsProvider>());
              if (direction == DismissDirection.startToEnd) {
                if (task.status == DownloadStatus.paused) {
                  provider.resumeTask(task.id);
                } else if (task.status == DownloadStatus.failed) {
                  provider.retryTask(task.id);
                } else if (task.status == DownloadStatus.completed) {
                  openFile(context, task.localFilePath,
                      context.read<SettingsProvider>());
                }
                return false;
              } else {
                final taskCopy = task;
                UndoService.instance.execute(
                  context: context,
                  message: '${task.fileName} deleted',
                  action: () async =>
                      provider.deleteTask(taskCopy.id, deleteFiles: false),
                  undo: () async {},
                );
                return true;
              }
            },
            child: cardWidget,
          );

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: semanticLabel,
      hint: L10n.of(context, 'double_tap_details_hint'),
      child: RepaintBoundary(
        child: Hero(
          tag: 'download_card_${task.id}',
          createRectTween: (begin, end) => RectTween(begin: begin, end: end),
          child: interactiveCard,
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ────────────────────────────────────────────────────────────────────────────

Color _statusColor(DownloadStatus status, bool isDark) {
  return switch (status) {
    DownloadStatus.queued =>
      isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
    DownloadStatus.downloading =>
      isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
    DownloadStatus.paused => isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
    DownloadStatus.completed =>
      isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
    DownloadStatus.failed => isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
    DownloadStatus.merging =>
      isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber, // FIX-B11
  };
}

Color getEffectiveCardAccent(
  DownloadTask task,
  DownloadProvider provider,
  bool isDark, {
  Color? filterColor,
}) {
  if (filterColor != null) return filterColor;
  final hasCategoryFilter = provider.categoryFilters.isNotEmpty;
  final hasStatusFilter = provider.statusFilter != 'All';
  if (hasCategoryFilter || hasStatusFilter) {
    return getActiveFilterColor(provider, isDark);
  }
  return _statusColor(task.status, isDark);
}

IconData _categoryIcon(String category) {
  return switch (category) {
    'Video' => Icons.movie_outlined,
    'Audio' => Icons.audiotrack_outlined,
    'Document' => Icons.description_outlined,
    'Archive' => Icons.folder_zip_outlined,
    'APK' => Icons.android_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

bool _isSeeding(DownloadTask task) =>
    task.status == DownloadStatus.completed &&
    task.isTorrent &&
    task.seedingEnabled;

// ────────────────────────────────────────────────────────────────────────────
// Card shell — status accent rail + tinted panel
// ────────────────────────────────────────────────────────────────────────────

class _CardShell extends StatelessWidget {
  final Widget child;
  final Color accent;
  final bool isDark;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _CardShell({
    required this.child,
    required this.accent,
    required this.isDark,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Semantics(
        container: true,
        hint: 'Double tap to view details',
        child: DmxCardShell(
          accent: accent,
          radius: 16,
          showRail: true,
          onTap: onTap,
          onLongPress: onLongPress,
          child: child,
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Status chip — pulses while downloading / seeding
// ────────────────────────────────────────────────────────────────────────────

// FIX P0-1: StatusChipPulseDriver — Replace Timer.periodic with efficient Ticker & stopAll
class StatusChipPulseDriver with WidgetsBindingObserver {
  StreamSubscription? _screenSub;

  StatusChipPulseDriver._internal() {
    WidgetsBinding.instance.addObserver(this);
    _screenSub = PowerMonitor.screenStateStream.listen((screenOn) {
      if (!screenOn) {
        _stop();
      } else if (_refCount > 0 && !DownloadEngine.isInBackground) {
        _start();
      }
    });
  }

  static final StatusChipPulseDriver instance = StatusChipPulseDriver._internal();
  factory StatusChipPulseDriver() => instance;

  static void stopAll() {
    instance._stop();
  }

  final ValueNotifier<double> value = ValueNotifier<double>(0.7);
  Ticker? _ticker;
  int _refCount = 0;
  int _visibleChips = 0;
  int get visibleChips => _visibleChips;
  double _current = 0.4;
  bool _increasing = true;
  DateTime? _lastTick;

  void incrementVisibleChips() {
    _visibleChips++;
  }

  void decrementVisibleChips() {
    _visibleChips = (_visibleChips - 1).clamp(0, 999999);
    if (_visibleChips == 0) {
      _stop();
    }
  }

  void addRef() {
    _refCount++;
    if (_ticker == null) {
      _start();
    }
  }

  void removeRef() {
    _refCount = (_refCount - 1).clamp(0, 999999);
    if (_refCount == 0) {
      _stop();
    }
  }

  void stop() {
    _stop();
  }

  void restartIfActive() {
    if (_refCount > 0 && !PowerMonitor.screenOff && !DownloadEngine.isInBackground) {
      _start();
    }
  }

  void _start() {
    if (PowerMonitor.screenOff || DownloadEngine.isInBackground || _refCount <= 0) return;
    _stop();
    _lastTick = DateTime.now();
    _ticker = Ticker((elapsed) {
      if (PowerMonitor.screenOff || DownloadEngine.isInBackground || _refCount <= 0) {
        _stop();
        return;
      }
      final now = DateTime.now();
      if (_lastTick != null && now.difference(_lastTick!).inMilliseconds < 45) {
        return;
      }
      _lastTick = now;
      if (_increasing) {
        _current += 0.03;
        if (_current >= 1.0) {
          _current = 1.0;
          _increasing = false;
        }
      } else {
        _current -= 0.03;
        if (_current <= 0.4) {
          _current = 0.4;
          _increasing = true;
        }
      }
      if ((value.value - _current).abs() > 0.01) {
        value.value = _current;
      }
    });
    _ticker?.start();
  }

  void _stop() {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _stop();
    } else if (state == AppLifecycleState.resumed && _refCount > 0) {
      if (!PowerMonitor.screenOff && !DownloadEngine.isInBackground) {
        _start();
      }
    }
  }

  void dispose() {
    _stop();
    _screenSub?.cancel();
    _screenSub = null;
    WidgetsBinding.instance.removeObserver(this);
  }
}

typedef _StatusChipPulseDriver = StatusChipPulseDriver;

class _StatusChip extends StatefulWidget {
  final DownloadTask task;
  final bool isDark;
  final String? overrideLabel;

  const _StatusChip({
    required this.task,
    required this.isDark,
    this.overrideLabel,
  });

  @override
  State<_StatusChip> createState() => _StatusChipState();
}

class _StatusChipState extends State<_StatusChip> {
  bool _hasActiveRef = false;

  bool _shouldPulse(DownloadTask task) {
    return task.status == DownloadStatus.downloading ||
        (task.status == DownloadStatus.completed &&
            task.isTorrent &&
            task.seedingEnabled);
  }

  Timer? _syncDebounce;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(_StatusChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.status != widget.task.status ||
        oldWidget.task.seedingEnabled != widget.task.seedingEnabled) {
      _syncPulse();
    }
  }

  void _syncPulse() {
    // FIX-P1-03: Debounce pulse driver reference updates during rapid scrolling/updates
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      final needsPulse =
          _shouldPulse(widget.task) && modernAnimationsAllowed(context);
      if (needsPulse && !_hasActiveRef) {
        _StatusChipPulseDriver().addRef();
        _hasActiveRef = true;
      } else if (!needsPulse && _hasActiveRef) {
        _StatusChipPulseDriver().removeRef();
        _hasActiveRef = false;
      }
    });
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    if (_hasActiveRef) {
      _StatusChipPulseDriver().removeRef();
      _hasActiveRef = false;
    }
    super.dispose();
  }

  IconData get _icon {
    final task = widget.task;
    if (_isSeeding(task)) return Icons.cloud_upload;
    if (task.status == DownloadStatus.paused &&
        task.errorMessage != null &&
        task.errorMessage!.contains('WiFi')) {
      return Icons.wifi_off_rounded;
    }
    return switch (task.status) {
      DownloadStatus.queued => Icons.hourglass_empty,
      DownloadStatus.downloading => Icons.downloading,
      DownloadStatus.paused => Icons.pause_circle,
      DownloadStatus.completed => Icons.check_circle,
      DownloadStatus.failed => Icons.error,
      DownloadStatus.merging => Icons.merge_type_rounded, // FIX-B11
    };
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final isDark = widget.isDark;
    final overrideLabel = widget.overrideLabel;
    final provider = context.read<DownloadProvider>();

    final isWifiWaiting = task.status == DownloadStatus.paused &&
        task.errorMessage != null &&
        task.errorMessage!.contains('WiFi');
    final color = isWifiWaiting
        ? (isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber)
        : getEffectiveCardAccent(task, provider, isDark);
    final label = overrideLabel ??
        (isWifiWaiting
            ? 'Waiting WiFi'
            : L10n.translateStatusName(context, task.status));

    final isScheduled = task.status == DownloadStatus.paused &&
        task.scheduledAt != null &&
        task.scheduledAt!.isAfter(DateTime.now());

    final isPulseActive =
        _shouldPulse(task) && modernAnimationsAllowed(context);

    Widget buildChipContainer(double pulseVal) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: color.withValues(alpha: 0.45 * pulseVal),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.08 * pulseVal),
              blurRadius: 6.0,
              spreadRadius: 0.5,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: responsiveFontSize(context, 12),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    final Widget chipContent = isPulseActive
        ? ValueListenableBuilder<double>(
            valueListenable: _StatusChipPulseDriver().value,
            builder: (context, pulseVal, _) => buildChipContainer(pulseVal),
          )
        : buildChipContainer(1.0);

    return RepaintBoundary(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          chipContent,
          if (isScheduled) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: formatLocalizedDateTime(context, task.scheduledAt!),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: AppTheme.chipDecoration(
                  color: AppTheme.neonAmber,
                  isDark: isDark,
                  radius: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.schedule_rounded,
                        size: 12, color: AppTheme.neonAmber),
                    const SizedBox(width: 4),
                    Text(
                      'Scheduled for ${formatLocalizedTime(context, task.scheduledAt!)}',
                      style: TextStyle(
                        fontSize: responsiveFontSize(context, 10),
                        color: AppTheme.neonAmber,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _QueuedSubtext extends StatelessWidget {
  final DownloadTask task;
  final bool isDark;

  const _QueuedSubtext({required this.task, required this.isDark});

  @override
  Widget build(BuildContext context) {
    if (task.status != DownloadStatus.queued) return const SizedBox.shrink();
    final activeCount =
        context.select((DownloadProvider p) => p.downloadingTasksCount);
    // FIX-P3: select() the single setting instead of watching the whole provider.
    final maxCount = context.select((SettingsProvider s) => s.maxDownloads);

    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(
        'Waiting for slot ($activeCount/$maxCount active)',
        style: TextStyle(
          fontSize: responsiveFontSize(context, 9.5),
          color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
        ),
      ),
    );
  }
}

class _TelemetryStrip extends StatelessWidget {
  final DownloadTask task;
  final bool isDark;
  final Color accent;
  final double seedingUploadSpeed;

  const _TelemetryStrip({
    required this.task,
    required this.isDark,
    required this.accent,
    this.seedingUploadSpeed = 0,
  });

  @override
  Widget build(BuildContext context) {
    final seeding = _isSeeding(task);
    final isCompleted = task.status == DownloadStatus.completed && !seeding;
    final isDownloading = task.status == DownloadStatus.downloading || seeding;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    final proto = ProtocolCache.get(task.url);
    final protoLabel = switch (proto) {
      ProtocolSupport.http3 => 'H3',
      ProtocolSupport.http2 => 'H2',
      _ => 'H1.1',
    };

    final protoBadge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue)
            .withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        protoLabel,
        style: TextStyle(
          fontSize: responsiveFontSize(context, 10),
          fontWeight: FontWeight.bold,
          fontFamily: 'Space Grotesk',
          color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        ),
      ),
    );

    // Completed downloads: clean single metadata line
    if (isCompleted) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            Icon(Icons.sd_storage_outlined, size: 14, color: mutedClr),
            const SizedBox(width: 4),
            Text(
              task.sizeFormatted,
              style: AppTheme.dataStyle(
                isDark: isDark,
                size: 12,
                weight: FontWeight.w600,
                color: secClr,
              ),
            ),
            const Spacer(),
            protoBadge,
          ],
        ),
      );
    }

    // Active downloading or seeding: 2-row live telemetry with sparkline
    if (isDownloading) {
      // FIX-UI-05: Show correct speed for seeding torrents
      final speedText = seeding
          ? '${formatBytes(seedingUploadSpeed)}/s'
          : task.speedFormatted;
      final etaText = seeding ? 'SEEDING' : task.etaFormatted;

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.speed_rounded, size: 14, color: accent),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    speedText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.dataStyle(
                      isDark: isDark,
                      size: 12,
                      weight: FontWeight.bold,
                      color: accent,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Icon(Icons.schedule_rounded, size: 14, color: mutedClr),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    etaText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.dataStyle(
                      isDark: isDark,
                      size: 12,
                      color: secClr,
                    ),
                  ),
                ),
                const Spacer(),
                Builder(
                  builder: (context) {
                    final provider = context.read<DownloadProvider>();
                    final history = provider.getSpeedHistory(task.id);
                    if (history.length >= 2) {
                      final screenW = MediaQuery.sizeOf(context).width;
                      final sparkWidth =
                          screenW < 340 ? 45.0 : (screenW < 400 ? 60.0 : 80.0);
                      return _CardSparklineGraph(
                        history: history,
                        color: accent,
                        width: sparkWidth,
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.sd_storage_outlined, size: 14, color: mutedClr),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '${task.downloadedSizeFormatted} / ${task.sizeFormatted}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.dataStyle(
                      isDark: isDark,
                      size: 11,
                      color: secClr,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                protoBadge,
              ],
            ),
          ],
        ),
      );
    }

    // FIX-AUDIT-C3: Update speed text for paused/queued/merging/failed
    final speedText = switch (task.status) {
      DownloadStatus.queued => 'Queued',
      DownloadStatus.paused => 'Paused',
      DownloadStatus.downloading => task.speedFormatted,
      DownloadStatus.completed =>
        seeding ? '${formatBytes(seedingUploadSpeed)}/s' : 'Done',
      DownloadStatus.failed => '—',
      DownloadStatus.merging => 'Merging…',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Icon(Icons.sd_storage_outlined, size: 14, color: mutedClr),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              task.downloadedBytes > 0
                  ? '${task.downloadedSizeFormatted} / ${task.sizeFormatted}'
                  : task.sizeFormatted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.dataStyle(
                isDark: isDark,
                size: 12,
                weight: FontWeight.w600,
                color: secClr,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            speedText,
            style: AppTheme.dataStyle(
              isDark: isDark,
              size: 11,
              weight: FontWeight.w600,
              color: mutedClr,
            ),
          ),
          const SizedBox(width: 8),
          protoBadge,
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Progress — chunked bar + total percentage readout
// ────────────────────────────────────────────────────────────────────────────

class _ChunkedProgressBar extends StatelessWidget {
  final DownloadTask task;
  final bool isDark;
  final Color color;

  const _ChunkedProgressBar({
    required this.task,
    required this.isDark,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final chunks = task.sanitizedChunks;
    final Widget bar;
    if (task.isTorrent || chunks.length <= 1 || task.hasMergedAudio) {
      final provider = context.read<DownloadProvider>();
      bar = RepaintBoundary(
        child: IsolatedProgressBar(
          progress: provider.progressNotifier(task.id),
          isDark: isDark,
          isTorrent: task.isTorrent,
          height: 8,
        ),
      );
    } else {
      // FIX(UI4): Isolate multi-chunk bar repaints
      bar = RepaintBoundary(
        child: Selector<DownloadProvider, List<double>>(
          selector: (_, p) {
            final t = p.taskById(task.id);
            return t?.sanitizedChunks ?? [];
          },
          builder: (_, liveChunks, __) {
            final activeChunks = liveChunks.isNotEmpty ? liveChunks : chunks;
            return Row(
              children: List.generate(activeChunks.length, (i) {
                // FIX-UI-01: Clamp chunk values to [0, 1]
                final raw = activeChunks[i];
                final p = raw.isNaN ? 0.0 : raw.clamp(0.0, 1.0);
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: i == 0 ? 0 : 2.5,
                      right: i == activeChunks.length - 1 ? 0 : 2.5,
                    ),
                    child: Stack(
                      children: [
                        Container(
                          height: 8,
                          decoration: AppTheme.progressTrack(
                            isDark: isDark,
                            radius: 3,
                          ),
                        ),
                        FractionallySizedBox(
                          widthFactor: p,
                          child: Container(
                            height: 8,
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            );
          },
        ),
      );
    }

    final Widget effectiveBar;
    if (task.status == DownloadStatus.downloading) {
      effectiveBar = TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.6, end: 1.0),
        duration: const Duration(milliseconds: 1500),
        builder: (context, opacity, child) {
          return Opacity(opacity: opacity, child: child);
        },
        child: bar,
      );
    } else {
      effectiveBar = bar;
    }

    return XdmSemantics.progress(
      label: 'Download progress',
      value: task.progress,
      child: effectiveBar,
    );
  }
}

class _ProgressRow extends StatelessWidget {
  final DownloadTask task;
  final bool isDark;
  final Color color;

  const _ProgressRow({
    required this.task,
    required this.isDark,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isDownloading = task.status == DownloadStatus.downloading;
    final showIndeterminate =
        (task.hasUnknownSize || task.progress == -1.0) && isDownloading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: showIndeterminate
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        minHeight: 8,
                        color: color,
                        backgroundColor: color.withValues(alpha: 0.15),
                      ),
                    )
                  : _ChunkedProgressBar(
                      task: task, isDark: isDark, color: color),
            ),
            const SizedBox(width: 10),
            // Total percentage or byte count readout
            SizedBox(
              width: showIndeterminate ? 80 : 48,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  showIndeterminate
                      ? formatBytes(task.downloadedBytes)
                      : task.progressPercentString,
                  textAlign: TextAlign.end,
                  style: AppTheme.dataStyle(
                    isDark: isDark,
                    size: showIndeterminate ? 11 : 13,
                    weight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ),
            ),
          ],
        ),
        // FIX(05): Audio progress indicator for YouTube downloads with separate audio track
        if (task.hasMergedAudio) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.audiotrack,
                  size: 12, color: color.withValues(alpha: 0.8)),
              const SizedBox(width: 4),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: task.audioProgressPercent,
                    minHeight: 3,
                    color: color,
                    backgroundColor: color.withValues(alpha: 0.15),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                task.audioProgressString,
                style: AppTheme.dataStyle(
                  isDark: isDark,
                  size: 10,
                  weight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        ],
        // FIX(09 & FIX-17): Display status message / partial size indicator
        if (task.isTotalSizePartial) ...[
          const SizedBox(height: 2),
          Text(
            'Video size unknown',
            style: AppTheme.microLabel(isDark: isDark, color: color, size: 9),
          ),
        ] else if (task.statusMessage != null &&
            task.statusMessage!.isNotEmpty &&
            (task.hasUnknownSize || isDownloading)) ...[
          const SizedBox(height: 2),
          Text(
            task.statusMessage!,
            style: AppTheme.microLabel(isDark: isDark, color: color, size: 9),
          ),
        ],
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Control cluster — pause / resume / retry / open / delete
// (torrent pause & resume go through the same provider calls; the provider
//  now validates the native torrent handle so resume actually re-attaches)
// ────────────────────────────────────────────────────────────────────────────

class _ControlButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;
  final String tooltip;
  final bool filled;
  final bool isLoading;

  const _ControlButton({
    super.key,
    required this.icon,
    required this.color,
    required this.onPressed,
    required this.tooltip,
    this.filled = false,
    this.isLoading = false,
  });

  @override
  State<_ControlButton> createState() => _ControlButtonState();
}

class _ControlButtonState extends State<_ControlButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: Center(
          child: Tooltip(
            message: widget.tooltip,
            child: GestureDetector(
              onTapDown: widget.isLoading || widget.onPressed == null
                  ? null
                  : (_) => setState(() => _pressed = true),
              onTapUp: widget.isLoading || widget.onPressed == null
                  ? null
                  : (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              onTap: widget.isLoading
                  ? null
                  : () {
                      HapticFeedback.lightImpact();
                      widget.onPressed?.call();
                    },
              child: AnimatedScale(
                scale: _pressed ? 0.85 : 1.0,
                duration: AppTheme.motionFast,
                curve: AppTheme.motionSpring,
                child: AnimatedContainer(
                  duration: AppTheme.motionBase,
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: widget.filled
                        ? widget.color
                        : widget.color.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: widget.color
                          .withValues(alpha: widget.filled ? 0 : 0.25),
                      width: 0.8,
                    ),
                  ),
                  child: Center(
                    child: widget.isLoading
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                widget.filled
                                    ? AppTheme.inkOn(widget.color)
                                    : widget.color,
                              ),
                            ),
                          )
                        : AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            switchInCurve: Curves.easeOutBack,
                            switchOutCurve: Curves.easeIn,
                            transitionBuilder: (child, anim) =>
                                RotationTransition(
                              turns: Tween<double>(begin: 0.75, end: 1.0)
                                  .animate(anim),
                              child:
                                  FadeTransition(opacity: anim, child: child),
                            ),
                            child: Icon(
                              widget.icon,
                              key: ValueKey(widget.icon),
                              size: 18,
                              color: widget.filled
                                  ? AppTheme.inkOn(widget.color)
                                  : widget.color,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ControlCluster extends StatelessWidget with HapticHelper {
  final DownloadTask task;

  const _ControlCluster({required this.task});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<DownloadProvider>();
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final accent = getEffectiveCardAccent(task, provider, isDark);
    final isPending = context
        .select((DownloadProvider p) => p.isTaskOperationPending(task.id));
    final isRtl = L10n.isRtl(context);

    Widget actionBtn;

    if (isPending) {
      actionBtn = _ControlButton(
        key: ValueKey('pending_${task.id}'),
        icon: task.status == DownloadStatus.downloading
            ? Icons.pause_rounded
            : Icons.play_arrow_rounded,
        color: accent,
        filled: true,
        isLoading: true,
        tooltip: isRtl ? 'جاري المعالجة...' : 'Processing...',
        onPressed: null,
      );
    } else if (task.status == DownloadStatus.downloading) {
      actionBtn = _ControlButton(
        key: ValueKey('pause_${task.id}'),
        icon: Icons.pause_rounded,
        color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
        tooltip: L10n.of(context, 'pause_btn'),
        onPressed: () {
          triggerHaptic(settings);
          provider.pauseTask(task.id);
        },
      );
    } else if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.queued) {
      actionBtn = _ControlButton(
        key: ValueKey('resume_${task.id}'),
        icon: Icons.play_arrow_rounded,
        color: accent,
        filled: true,
        tooltip: task.status == DownloadStatus.queued
            ? L10n.of(context, 'start_btn')
            : L10n.of(context, 'resume_btn'),
        onPressed: () {
          triggerHaptic(settings);
          provider.resumeTask(task.id);
        },
      );
    } else if (task.status == DownloadStatus.failed) {
      actionBtn = _ControlButton(
        key: ValueKey('retry_${task.id}'),
        icon: Icons.refresh_rounded,
        color: accent,
        filled: true,
        tooltip: L10n.of(context, 'retry_label'),
        onPressed: () {
          triggerHaptic(settings);
          provider.retryTask(task.id);
        },
      );
    } else if (task.status == DownloadStatus.merging) {
      actionBtn = Row(
        key: ValueKey('merging_${task.id}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(accent),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Merging…',
            style: TextStyle(color: accent, fontSize: 12),
          ),
        ],
      );
    } else if (task.status == DownloadStatus.completed) {
      actionBtn = _ControlButton(
        key: ValueKey('open_${task.id}'),
        icon: Icons.folder_open_rounded,
        color: accent,
        filled: true,
        tooltip: L10n.of(context, 'open_file_btn'),
        onPressed: () async {
          triggerHaptic(settings);
          final path = task.localFilePath;
          final fileExists = path.isNotEmpty &&
              (await File(path).exists() || await Directory(path).exists());
          if (!fileExists) {
            await provider.markCompletedFileMissing(task.id);
            if (context.mounted) {
              ThemedSnackbar.show(
                context,
                message: L10n.of(context, 'file_missing_msg'),
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                icon: Icons.error_outline,
                isDarkMode: isDark,
              );
            }
            return;
          }
          if (context.mounted) {
            openFile(context, task.localFilePath, settings);
          }
        },
      );
    } else {
      actionBtn = const SizedBox.shrink();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOutBack,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (Widget child, Animation<double> animation) {
            return ScaleTransition(
              scale: animation,
              child: FadeTransition(
                opacity: animation,
                child: child,
              ),
            );
          },
          child: actionBtn,
        ),
        const SizedBox(width: 6),
        _ControlButton(
          icon: Icons.more_vert_rounded,
          color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
          tooltip: L10n.of(context, 'options_btn'),
          onPressed: () => _showAdvancedControls(context, task, settings),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Status message / error rows
// ────────────────────────────────────────────────────────────────────────────

IconData _statusMessageIcon(String? message) {
  if (message == null) return Icons.info_outline_rounded;
  final m = message.toLowerCase();
  if (m.contains('wifi')) return Icons.wifi_off_rounded;
  if (m.contains('network') || m.contains('waiting')) {
    return Icons.signal_wifi_bad_rounded;
  }
  if (m.contains('merg')) return Icons.merge_type_rounded;
  if (m.contains('forbidden') || m.contains('403')) return Icons.block_rounded;
  if (m.contains('retry') || m.contains('retrying')) {
    return Icons.refresh_rounded;
  }
  if (m.contains('schedul')) return Icons.schedule_rounded;
  if (m.contains('paused') || m.contains('orphan')) {
    return Icons.pause_circle_outline_rounded;
  }
  if (m.contains('error') || m.contains('fail')) {
    return Icons.error_outline_rounded;
  }
  return Icons.info_outline_rounded;
}

class _NoticeRow extends StatelessWidget {
  final String text;
  final Color color;
  final IconData icon;
  final bool isDark;

  const _NoticeRow({
    required this.text,
    required this.color,
    required this.icon,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 0.8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: AppTheme.dataStyle(
                isDark: isDark,
                size: 10,
                weight: FontWeight.w600,
                color: color,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Recovery-suggestion row shown under a failed card's error message.
class _RecoveryHintRow extends StatelessWidget {
  final String text;
  final bool isDark;

  const _RecoveryHintRow({required this.text, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final hintColor = isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(
            Icons.lightbulb_outline,
            size: 12,
            color: hintColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: AppTheme.dataStyle(
                isDark: isDark,
                size: 10,
                weight: FontWeight.w500,
                color: hintColor,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Variant 1 — Single file
// ────────────────────────────────────────────────────────────────────────────

class _FileCard extends StatelessWidget with HapticHelper {
  final DownloadTask task;
  final bool compact;

  const _FileCard({required this.task, required this.compact});

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final provider = context.read<DownloadProvider>();
    final statusColor = getEffectiveCardAccent(task, provider, isDark);
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    final isSmallScreen = MediaQuery.sizeOf(context).width < 360;
    final horizPadding = isSmallScreen ? 10.0 : (compact ? 12.0 : 14.0);
    final vertPadding = isSmallScreen ? 10.0 : (compact ? 10.0 : 14.0);
    final itemGap = isSmallScreen ? 8.0 : 12.0;

    return _CardShell(
      accent: statusColor,
      isDark: isDark,
      onTap: () {
        triggerHaptic(settings);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => DetailsScreen(taskId: task.id)),
        );
      },
      onLongPress: () => _showAdvancedControls(context, task, settings),
      child: ClipRect(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizPadding,
            vertical: vertPadding,
          ),
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: compact ? 38 : 44,
                      height: compact ? 38 : 44,
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: statusColor.withValues(alpha: 0.15),
                          width: 0.8,
                        ),
                      ),
                      child: Icon(
                        _categoryIcon(task.category),
                        color: statusColor,
                        size: compact ? 18 : 21,
                      ),
                    ),
                    SizedBox(width: itemGap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Tooltip(
                                  message: task.fileName,
                                  child: Text(
                                    task.fileName,
                                    textDirection: TextDirection.ltr,
                                    style: AppTheme.dataStyle(
                                      isDark: isDark,
                                      size: compact ? 13 : 14,
                                      weight: FontWeight.w700,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              if (task.siteDisplayName != null) ...[
                                const SizedBox(width: 4),
                                _SiteBadge(
                                  name: task.siteDisplayName!,
                                  isDark: isDark,
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 5),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _StatusChip(task: task, isDark: isDark),
                              Text(
                                L10n.translateCategory(
                                  context,
                                  task.category,
                                ).toUpperCase(),
                                style: AppTheme.microLabel(
                                  isDark: isDark,
                                  size: 8.5,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    _ControlCluster(task: task),
                  ],
                ),
                const SizedBox(height: 8),
                _TelemetryStrip(
                    task: task, isDark: isDark, accent: statusColor),
                const SizedBox(height: 8),
                _ProgressRow(task: task, isDark: isDark, color: statusColor),
                if (task.statusMessage != null &&
                    task.statusMessage!.isNotEmpty &&
                    task.status != DownloadStatus.completed)
                  _NoticeRow(
                    text: task.statusMessage!,
                    color:
                        isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
                    icon: _statusMessageIcon(task.statusMessage),
                    isDark: isDark,
                  ),
                if (task.status == DownloadStatus.failed &&
                    task.errorMessage != null)
                  _NoticeRow(
                    text: task.errorMessage!,
                    color: statusColor,
                    icon: Icons.error_outline,
                    isDark: isDark,
                  ),
                if (task.status == DownloadStatus.failed &&
                    task.recoveryHint != null &&
                    task.recoveryHint!.isNotEmpty)
                  _RecoveryHintRow(text: task.recoveryHint!, isDark: isDark),
                if (task.status == DownloadStatus.downloading)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: Text(
                        '${task.threadCount} CH',
                        style: AppTheme.microLabel(
                          isDark: isDark,
                          color: mutedClr,
                          size: 8.5,
                        ),
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
}

// ────────────────────────────────────────────────────────────────────────────
// Variant 2 — Media (single video / audio / playlist item)
// ────────────────────────────────────────────────────────────────────────────

class _MediaCard extends StatelessWidget with HapticHelper {
  final DownloadTask task;
  final bool compact;

  const _MediaCard({required this.task, required this.compact});

  String get _qualityLabel {
    final preset = task.youtubeQualityPreset ?? '';
    if (preset == 'audio_only') return 'AUDIO';
    if (preset == 'best_combined' || preset == 'best') return 'BEST';
    if (preset == 'best_muxed') return 'MP4';
    return preset.toUpperCase();
  }

  bool get _hasAudioTrack =>
      task.mergedAudioUrl != null && task.mergedAudioUrl!.isNotEmpty;

  bool get _isAudioOnly => task.youtubeQualityPreset == 'audio_only';

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final provider = context.read<DownloadProvider>();
    final statusColor = getEffectiveCardAccent(task, provider, isDark);
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final qualityColor = _isAudioOnly
        ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
        : (isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan);

    final isSmallScreen = MediaQuery.sizeOf(context).width < 360;
    final horizPadding = isSmallScreen ? 10.0 : (compact ? 12.0 : 14.0);
    final vertPadding = isSmallScreen ? 10.0 : (compact ? 10.0 : 14.0);
    final itemGap = isSmallScreen ? 8.0 : 12.0;

    return _CardShell(
      accent: statusColor,
      isDark: isDark,
      onTap: () {
        triggerHaptic(settings);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => DetailsScreen(taskId: task.id)),
        );
      },
      onLongPress: () => _showAdvancedControls(context, task, settings),
      child: ClipRect(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizPadding,
            vertical: vertPadding,
          ),
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: compact ? 46 : 56,
                      height: compact ? 34 : 40,
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: statusColor.withValues(alpha: 0.15),
                          width: 0.8,
                        ),
                        image: task.thumbnailUrl != null &&
                                task.thumbnailUrl!.isNotEmpty
                            ? DecorationImage(
                                image: CachedNetworkImageProvider(
                                  task.thumbnailUrl!.startsWith('//')
                                      ? 'https:${task.thumbnailUrl}'
                                      : task.thumbnailUrl!,
                                  maxWidth: 144,
                                ),
                                fit: BoxFit.cover,
                                onError: (context, error) {
                                  // Fallback to icon if image fails to load
                                },
                              )
                            : null,
                      ),
                      child: task.thumbnailUrl != null &&
                              task.thumbnailUrl!.isNotEmpty
                          ? null
                          : Icon(
                              _isAudioOnly
                                  ? Icons.audiotrack_rounded
                                  : Icons.play_arrow_rounded,
                              color: statusColor,
                              size: compact ? 18 : 22,
                            ),
                    ),
                    SizedBox(width: itemGap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Tooltip(
                                  message: task.fileName,
                                  child: Text(
                                    task.fileName,
                                    textDirection: TextDirection.ltr,
                                    style: AppTheme.dataStyle(
                                      isDark: isDark,
                                      size: compact ? 13 : 14,
                                      weight: FontWeight.w700,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              if (task.siteDisplayName != null) ...[
                                const SizedBox(width: 4),
                                _SiteBadge(
                                  name: task.siteDisplayName!,
                                  isDark: isDark,
                                ),
                              ],
                            ],
                          ),
                          SizedBox(height: compact ? 2 : 3),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _StatusChip(task: task, isDark: isDark),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2.5,
                                ),
                                decoration: BoxDecoration(
                                  color: qualityColor.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(7),
                                  border: Border.all(
                                    color: qualityColor.withValues(alpha: 0.3),
                                    width: 0.8,
                                  ),
                                ),
                                child: Text(
                                  _qualityLabel,
                                  style: AppTheme.microLabel(
                                    isDark: isDark,
                                    color: qualityColor,
                                    size: 8,
                                  ),
                                ),
                              ),
                              if (_hasAudioTrack && !_isAudioOnly)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: mutedClr.withValues(alpha: 0.10),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.audio_file_rounded,
                                        size: 11,
                                        color: mutedClr,
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        'A/V',
                                        style: AppTheme.microLabel(
                                          isDark: isDark,
                                          size: 8,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          _QueuedSubtext(task: task, isDark: isDark),
                        ],
                      ),
                    ),
                    _ControlCluster(task: task),
                  ],
                ),
                SizedBox(height: compact ? 2 : 4),
                _TelemetryStrip(
                    task: task, isDark: isDark, accent: statusColor),
                SizedBox(height: compact ? 2 : 4),
                _ProgressRow(task: task, isDark: isDark, color: statusColor),
                if (task.statusMessage != null &&
                    task.statusMessage!.isNotEmpty &&
                    task.status != DownloadStatus.completed)
                  _NoticeRow(
                    text: task.statusMessage!,
                    color:
                        isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
                    icon: _statusMessageIcon(task.statusMessage),
                    isDark: isDark,
                  ),
                if (task.status == DownloadStatus.failed &&
                    task.errorMessage != null)
                  _NoticeRow(
                    text: task.errorMessage!,
                    color: statusColor,
                    icon: Icons.error_outline,
                    isDark: isDark,
                  ),
                if (task.status == DownloadStatus.failed &&
                    task.recoveryHint != null &&
                    task.recoveryHint!.isNotEmpty)
                  _RecoveryHintRow(text: task.recoveryHint!, isDark: isDark),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Variant 3 — Torrent / magnet
// ────────────────────────────────────────────────────────────────────────────

class _TorrentCard extends StatefulWidget {
  final DownloadTask task;
  final bool compact;

  const _TorrentCard({required this.task, required this.compact});

  @override
  State<_TorrentCard> createState() => _TorrentCardState();
}

class _TorrentCardState extends State<_TorrentCard> with HapticHelper {
  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final provider = context.read<DownloadProvider>();
    final statusColor = getEffectiveCardAccent(widget.task, provider, isDark);
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final isMagnet = widget.task.url.startsWith('magnet:');
    final seeding = _isSeeding(widget.task);

    return Selector<DownloadProvider,
        ({int seeds, int peers, double uploadSpeed})>(
      selector: (context, provider) => (
        seeds: provider.getTorrentSeeds(widget.task.id),
        peers: provider.getTorrentPeers(widget.task.id),
        uploadSpeed: provider.getTorrentUploadSpeed(widget.task.id),
      ),
      builder: (context, stats, _) {
        final fileCount = widget.task.torrentFiles?.length ?? 0;
        final selectedCount = widget.task.torrentFiles
                ?.where((f) => isTorrentFileSelected(f))
                .length ??
            0;

        final isSmallScreen = MediaQuery.sizeOf(context).width < 360;
        final horizPadding =
            isSmallScreen ? 10.0 : (widget.compact ? 12.0 : 14.0);
        final vertPadding =
            isSmallScreen ? 10.0 : (widget.compact ? 10.0 : 14.0);
        final itemGap = isSmallScreen ? 8.0 : 12.0;

        return _CardShell(
          accent: statusColor,
          isDark: isDark,
          onTap: () {
            triggerHaptic(settings);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DetailsScreen(taskId: widget.task.id),
              ),
            );
          },
          onLongPress: () =>
              _showAdvancedControls(context, widget.task, settings),
          child: ClipRect(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: horizPadding,
                vertical: vertPadding,
              ),
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: widget.compact ? 38 : 44,
                          height: widget.compact ? 38 : 44,
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: statusColor.withValues(alpha: 0.15),
                              width: 0.8,
                            ),
                          ),
                          child: Icon(
                            isMagnet
                                ? Icons.link_rounded
                                : Icons.cloud_download_rounded,
                            color: statusColor,
                            size: widget.compact ? 18 : 21,
                          ),
                        ),
                        SizedBox(width: itemGap),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Tooltip(
                                      message: widget.task.fileName,
                                      child: Text(
                                        widget.task.fileName,
                                        textDirection: TextDirection.ltr,
                                        style: AppTheme.dataStyle(
                                          isDark: isDark,
                                          size: widget.compact ? 13 : 14,
                                          weight: FontWeight.w700,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                  if (widget.task.siteDisplayName != null) ...[
                                    const SizedBox(width: 4),
                                    _SiteBadge(
                                      name: widget.task.siteDisplayName!,
                                      isDark: isDark,
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 5),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  // FIX-UI-04: Show "Fetching metadata…" for magnets with fileSize == 0
                                  _StatusChip(
                                    task: widget.task,
                                    isDark: isDark,
                                    overrideLabel: (widget.task.isTorrent &&
                                            widget.task.resolvedFileSize == 0 &&
                                            widget.task.status ==
                                                DownloadStatus.downloading)
                                        ? (isRtl
                                            ? 'جاري جلب البيانات…'
                                            : 'Fetching metadata…')
                                        : (seeding
                                            ? (isRtl ? 'مشاركة' : 'SEEDING')
                                            : null),
                                  ),

                                  _PeerChip(
                                    icon: Icons.arrow_upward_rounded,
                                    label: '${stats.seeds}',
                                    color: greenClr,
                                    isDark: isDark,
                                  ),
                                  _PeerChip(
                                    icon: Icons.arrow_downward_rounded,
                                    label: '${stats.peers}',
                                    color: violetClr,
                                    isDark: isDark,
                                  ),
                                  if (fileCount > 0)
                                    _PeerChip(
                                      icon: Icons.folder_outlined,
                                      label: '$selectedCount/$fileCount',
                                      color: mutedClr,
                                      isDark: isDark,
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Column(children: [_ControlCluster(task: widget.task)]),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Telemetry: downloaded / total / elapsed / remain / speed
                    _TelemetryStrip(
                      task: widget.task,
                      isDark: isDark,
                      accent: statusColor,
                      seedingUploadSpeed: stats.uploadSpeed,
                    ),
                    const SizedBox(height: 8),
                    // Total progress + total percentage
                    Builder(builder: (context) {
                      final files = widget.task.torrentFiles ?? [];
                      final isChecking = widget.task.statusMessage
                              ?.toLowerCase()
                              .contains('checking') ==
                          true; // FIX-B10: case-insensitive
                      final displayFiles = files.map((f) {
                        final selected = isTorrentFileSelected(f);
                        final length = (f['length'] as num?)?.toInt() ?? 0;
                        final rawDownloaded =
                            (f['downloadedBytes'] as num?)?.toInt() ?? 0;
                        // -1 = engine has no data; keep 0 but mark as estimated
                        final downloaded =
                            rawDownloaded < 0 ? 0 : rawDownloaded;
                        final isEstimated =
                            (f['progressEstimated'] as bool?) ?? false;
                        final effectiveDownloaded = isChecking
                            ? downloaded
                            : (widget.task.status == DownloadStatus.completed &&
                                    selected
                                ? length
                                : downloaded);
                        return {
                          ...f,
                          'downloadedBytes': effectiveDownloaded,
                          'progressEstimated': isEstimated,
                        };
                      }).toList();
                      final selectedFiles = displayFiles
                          .where((f) => isTorrentFileSelected(f))
                          .toList();
                      final totalLen = selectedFiles.fold<int>(
                        0,
                        (s, f) {
                          final len = (f['length'] as num?)?.toInt() ?? 0;
                          return s + (len < 0 ? 0 : len);
                        },
                      );
                      final totalDl = selectedFiles.fold<int>(
                        0,
                        (s, f) {
                          final dl =
                              (f['downloadedBytes'] as num?)?.toInt() ?? 0;
                          return s + (dl < 0 ? 0 : dl);
                        },
                      );
                      // FIX-CLAMP: guard against totalDl > totalLen (stale per-file data)
                      // Fall back to the provider's known totalFileBytes when the local
                      // file list is empty (e.g. first tick after a session restore).
                      final hasTorrentFiles =
                          widget.task.torrentFiles != null &&
                              widget.task.torrentFiles!.isNotEmpty;
                      final effectiveTotalLen = totalLen > 0
                          ? totalLen
                          : (!hasTorrentFiles && widget.task.fileSize > 0
                              ? widget.task.fileSize
                              : 0);
                      final overallProgress = effectiveTotalLen > 0
                          ? (totalDl.clamp(0, effectiveTotalLen) /
                                  effectiveTotalLen)
                              .clamp(0.0, 1.0)
                          : -1.0;
                      final pctLabel = overallProgress < 0
                          ? (totalDl > 0
                              ? formatBytes(totalDl.toDouble())
                              : '0.0%')
                          : '${(overallProgress * 100).toStringAsFixed(1)}%';
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: overallProgress < 0
                                      ? const SizedBox(
                                          height: 8,
                                          child: LinearProgressIndicator(
                                              minHeight: 8),
                                        )
                                      : Stack(
                                          children: [
                                            Container(
                                              height: 8,
                                              decoration:
                                                  AppTheme.progressTrack(
                                                isDark: isDark,
                                              ),
                                            ),
                                            AnimatedFractionallySizedBox(
                                              widthFactor: overallProgress
                                                  .clamp(0.0, 1.0),
                                              duration: const Duration(
                                                  milliseconds: 400),
                                              curve: Curves.easeOut,
                                              child: Container(
                                                height: 8,
                                                decoration: BoxDecoration(
                                                  color: statusColor,
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              SizedBox(
                                width: 48,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    pctLabel,
                                    textAlign: TextAlign.end,
                                    style: AppTheme.dataStyle(
                                      isDark: isDark,
                                      size: 13,
                                      weight: FontWeight.w800,
                                      color: statusColor,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    }),
                    // Per-file percentages (isolated rebuild via dedicated StatefulWidget)
                    if (fileCount > 0) ...[
                      const SizedBox(height: 12),
                      _TorrentFileListSection(
                        task: widget.task,
                        isDark: isDark,
                        accent: statusColor,
                      ),
                    ],
                    // Seeding toggle once completed
                    if (widget.task.status == DownloadStatus.completed) ...[
                      const SizedBox(height: 10),
                      Divider(
                        color: isDark
                            ? AppTheme.borderSubtle
                            : AppTheme.lightBorderSubtle,
                        height: 1,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            Icons.cloud_upload_outlined,
                            size: 14,
                            color: violetClr,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            isRtl ? 'مشاركة التورنت' : 'Seed this torrent',
                            style: AppTheme.dataStyle(
                              isDark: isDark,
                              size: 11,
                              weight: FontWeight.w600,
                            ),
                          ),
                          if (widget.task.seedingEnabled) ...[
                            const SizedBox(width: 8),
                            Text(
                              'Ratio: ${widget.task.seedingRatio.toStringAsFixed(2)}',
                              style: AppTheme.dataStyle(
                                isDark: isDark,
                                size: 10,
                                color: violetClr,
                                weight: FontWeight.w700,
                              ),
                            ),
                          ],
                          const Spacer(),
                          Switch(
                            value: widget.task.seedingEnabled,
                            onChanged: (val) {
                              triggerHaptic(settings);
                              context
                                  .read<DownloadProvider>()
                                  .updateTaskSeeding(
                                    widget.task.id,
                                    enabled: val,
                                  );
                            },
                            activeThumbColor: violetClr,
                          ),
                        ],
                      ),
                    ],
                    if (widget.task.status == DownloadStatus.failed &&
                        widget.task.errorMessage != null)
                      _NoticeRow(
                        text: widget.task.errorMessage!,
                        color: statusColor,
                        icon: Icons.error_outline,
                        isDark: isDark,
                      ),
                    if (widget.task.status == DownloadStatus.failed &&
                        widget.task.recoveryHint != null &&
                        widget.task.recoveryHint!.isNotEmpty)
                      _RecoveryHintRow(
                        text: widget.task.recoveryHint!,
                        isDark: isDark,
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
}

// FIX(R4): Isolated rebuild section for torrent file list
class _TorrentFileListSection extends StatefulWidget {
  final DownloadTask task;
  final bool isDark;
  final Color accent;

  const _TorrentFileListSection({
    required this.task,
    required this.isDark,
    required this.accent,
  });

  @override
  State<_TorrentFileListSection> createState() =>
      _TorrentFileListSectionState();
}

class _TorrentFileListSectionState extends State<_TorrentFileListSection>
    with HapticHelper {
  bool _showAllFiles = false;
  static const int _collapsedFileCount = 4;

  @override
  Widget build(BuildContext context) {
    // FIX-H6: Wrap torrent file list in Selector to get live per-file percentages
    return Selector<DownloadProvider, List<Map<String, dynamic>>?>(
      selector: (_, p) =>
          p.taskById(widget.task.id)?.torrentFiles ?? widget.task.torrentFiles,
      shouldRebuild: (prev, next) {
        if (prev == null && next == null) return false;
        if (prev == null || next == null) return true;
        if (prev.length != next.length) return true;
        if (prev.isEmpty) return false;
        final prevBytes = (prev.first['downloadedBytes'] as num?)?.toInt();
        final nextBytes = (next.first['downloadedBytes'] as num?)?.toInt();
        return prevBytes != nextBytes;
      },
      builder: (context, dynamicTorrentFiles, _) {
        try {
          final files = dynamicTorrentFiles ?? widget.task.torrentFiles ?? [];
          final isChecking = widget.task.statusMessage?.contains('checking') ==
                  true ||
              widget.task.statusMessage?.contains('Checking') == true; // FIX-B10
          final displayFiles = files.map((f) {
            final selected = isTorrentFileSelected(f);
            final length = (f['length'] as num?)?.toInt() ?? 0;
            final rawBytes = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
            // During a recheck the engine may report 0 temporarily;
            // keep the last known value so the bar doesn't flicker to 0.
            final downloaded = isChecking
                ? (length > 0
                    ? rawBytes.clamp(0, length)
                    : (rawBytes < 0 ? 0 : rawBytes))
                : (length > 0 ? rawBytes.clamp(0, length) : 0);
            final resolvedBytes =
                (widget.task.status == DownloadStatus.completed && selected)
                    ? length
                    : downloaded;

            return {...f, 'downloadedBytes': resolvedBytes};
          }).toList();

          final visible = _showAllFiles
              ? displayFiles
              : displayFiles.take(_collapsedFileCount).toList();
          final hiddenCount = displayFiles.length - visible.length;
          final mutedClr =
              widget.isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'FILES • ${files.where((f) => isTorrentFileSelected(f)).length}/${files.length}',
                  style: AppTheme.microLabel(isDark: widget.isDark, size: 8),
                ),
              ),
              ...visible.map(
                (f) => _TorrentFileRow(
                  file: f,
                  isDark: widget.isDark,
                  accent: widget.accent,
                  isChecking: isChecking, // FIX-B10
                ),
              ),
              if (hiddenCount > 0 || _showAllFiles)
                GestureDetector(
                  onTap: () {
                    triggerHaptic(context.read<SettingsProvider>());
                    setState(() => _showAllFiles = !_showAllFiles);
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _showAllFiles
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 14,
                          color: mutedClr,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _showAllFiles
                              ? 'SHOW LESS'
                              : '+$hiddenCount MORE FILE${hiddenCount == 1 ? '' : 'S'}',
                          style: AppTheme.microLabel(
                            isDark: widget.isDark,
                            color: mutedClr,
                            size: 8.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        } catch (e) {
          return Padding(
            padding: const EdgeInsetsDirectional.only(start: 12, bottom: 8),
            child: Text(
              'Corrupted torrent file list',
              style: AppTheme.microLabel(
                isDark: widget.isDark,
                color: widget.isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
              ),
            ),
          );
        }
      },
    );
  }
}

class _PeerChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool isDark;

  const _PeerChip({
    required this.icon,
    required this.label,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: AppTheme.dataStyle(isDark: isDark, color: color, size: 9),
          ),
        ],
      ),
    );
  }
}

/// One torrent file row: name, individual progress bar, per-file percentage,
/// and file size. Bytes come from the provider's disk-verified per-file
/// tracking (`downloadedBytes` inside `task.torrentFiles`).
class _TorrentFileRow extends StatelessWidget {
  final Map<String, dynamic> file;
  final bool isDark;
  final Color accent;
  final bool isChecking; // FIX-B10

  const _TorrentFileRow({
    required this.file,
    required this.isDark,
    required this.accent,
    this.isChecking = false, // FIX-B10
  });

  @override
  Widget build(BuildContext context) {
    final nameRaw = file['name'] as String?;
    // FIX-T-LEN: reject entries with a missing/invalid length before any
    // fraction math so a zero or negative length can never yield NaN %.
    final rawLen = (file['length'] as num?)?.toInt() ?? 0;
    if (file.isEmpty || nameRaw == null || rawLen < 0) {
      final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
      return Padding(
        padding: const EdgeInsetsDirectional.only(start: 12, bottom: 8),
        child: Text(
          'Unknown file',
          style:
              AppTheme.microLabel(isDark: isDark, color: mutedClr, size: 8.5),
        ),
      );
    }
    final selected = isTorrentFileSelected(file);
    final length = (file['length'] as num?)?.toInt() ?? 0;
    final safeLength = length < 0 ? 0 : length;
    final rawBytes = (file['downloadedBytes'] as num?)?.toInt() ?? 0;
    // -1 means "engine has no progress data" — fall back to 0 but keep
    // the estimated flag so the UI can show a hint instead of a hard 0.
    final hasEngineData = rawBytes >= 0;
    final downloaded = hasEngineData
        ? (safeLength > 0 ? rawBytes.clamp(0, safeLength) : 0)
        : 0;
    final p = safeLength > 0 ? (downloaded / safeLength).clamp(0.0, 1.0) : 0.0;
    final done = selected && p >= 1.0;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final name = (file['name'] as String? ?? '').replaceAll('+', ' ');

    final isEstimated = file['progressEstimated'] == true;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    // FIX(T-2): Show indeterminate indicator when downloadedBytes == 0 and selected
    final hadNoData = (file['_hadNoData'] as bool?) ?? false;
    final showIndeterminate =
        (downloaded == 0 || hadNoData) && isEstimated && selected && !done;
    final progressText = showIndeterminate
        ? '…'
        : (!hasEngineData && !isEstimated
            ? '…'
            : (isEstimated
                ? '≈${(p * 100).toStringAsFixed(0)}%'
                : '${(p * 100).toStringAsFixed(0)}%'));

    // FIX(M-4): Render unselected torrent files with reduced opacity
    return Opacity(
      opacity: selected ? 1.0 : 0.45,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 12, bottom: 8),
        child: Row(
          children: [
            Icon(
              done
                  ? Icons.check_circle_rounded
                  : selected
                      ? Icons.insert_drive_file_rounded
                      : Icons.block_rounded,
              size: 13,
              color: done ? greenClr : (selected ? accent : mutedClr),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: AppTheme.dataStyle(
                      isDark: isDark,
                      size: 10.5,
                      weight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // Progress bar — indeterminate while the engine is rechecking
                  // so a stale estimate is never rendered as a fixed percentage.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(1),
                    child: isChecking
                        ? const SizedBox(
                            height: 2,
                            child: LinearProgressIndicator(minHeight: 2),
                          )
                        : Stack(
                            children: [
                              Container(
                                height: 2,
                                decoration: AppTheme.progressTrack(
                                  isDark: isDark,
                                  radius: 1,
                                ),
                              ),
                              AnimatedFractionallySizedBox(
                                widthFactor: p.clamp(0.0, 1.0),
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOut,
                                child: Container(
                                  height: 2,
                                  decoration: BoxDecoration(
                                    color: isEstimated
                                        ? (done ? greenClr : accent)
                                            .withValues(alpha: 0.45)
                                        : (done ? greenClr : accent),
                                    borderRadius: BorderRadius.circular(1),
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // ── FIX-9: Show estimated indicator ──
            // Per-file percentage
            SizedBox(
              width: 44,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (isEstimated)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Tooltip(
                        message: isEstimated
                            ? 'Estimated — waiting for engine data'
                            : 'Confirmed by engine',
                        child: Icon(
                          Icons.help_outline,
                          size: 9,
                          color: mutedClr,
                        ),
                      ),
                    ),
                  if (isChecking)
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: mutedClr,
                      ),
                    ) // FIX-B10
                  else
                    Text(
                      progressText,
                      textAlign: TextAlign.end,
                      style: AppTheme.dataStyle(
                        isDark: isDark,
                        size: 10,
                        weight: FontWeight.w800,
                        color: done
                            ? greenClr
                            : isEstimated
                                ? textClr.withValues(alpha: 0.6)
                                : accent,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              child: Text(
                // FIX-8: When the engine hasn't reported any bytes yet
                // (rawBytes was −1 → clamped to 0) show "…" so the user
                // doesn't see a false "0 B / 1.2 GB" after a restart.
                rawBytes <= 0 && !done
                    ? '… / ${formatBytes(length.toDouble())}'
                    : '${formatBytes(downloaded.toDouble())} / ${formatBytes(length.toDouble())}',
                textAlign: TextAlign.end,
                style: AppTheme.dataStyle(
                  isDark: isDark,
                  size: 9,
                  weight: FontWeight.w500,
                  color: mutedClr,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Playlist group card — groups playlist videos into one card
// ────────────────────────────────────────────────────────────────────────────

class PlaylistGroupCard extends StatefulWidget {
  final String playlistId;
  final String title;
  final List<DownloadTask> items;

  const PlaylistGroupCard({
    super.key,
    required this.playlistId,
    required this.title,
    required this.items,
  });

  @override
  State<PlaylistGroupCard> createState() => _PlaylistGroupCardState();
}

class _PlaylistGroupCardState extends State<PlaylistGroupCard>
    with HapticHelper {
  bool _expanded = false;

  int get _completedCount =>
      widget.items.where((t) => t.status == DownloadStatus.completed).length;

  double get _overallProgress {
    // FIX-UI-01: Guard against zero/negative totals and clamp the
    // numerator so the bar never exceeds 100%.
    final total = widget.items.fold<int>(
        0, (s, t) => s + (t.resolvedFileSize > 0 ? t.resolvedFileSize : 0));
    if (total <= 0) return 0.0;
    final done = widget.items.fold<int>(
        0,
        (s, t) =>
            s +
            t.displayDownloadedBytes
                .clamp(0, t.resolvedFileSize > 0 ? t.resolvedFileSize : 0));
    return (done / total).clamp(0.0, 1.0);
  }

  bool get _anyDownloading =>
      widget.items.any((t) => t.status == DownloadStatus.downloading);

  bool get _allDone => _completedCount == widget.items.length;

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final provider = context.read<DownloadProvider>();
    final accent = _allDone
        ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
        : (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed);
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return _CardShell(
      accent: accent,
      isDark: isDark,
      onTap: () {
        triggerHaptic(settings);
        setState(() => _expanded = !_expanded);
      },
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.15),
                      width: 0.8,
                    ),
                  ),
                  child: Icon(
                    Icons.queue_music_rounded,
                    color: accent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: AppTheme.dataStyle(
                          isDark: isDark,
                          size: 14,
                          weight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: accent.withValues(alpha: 0.3),
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              isRtl
                                  ? 'قائمة تشغيل • ${widget.items.length} فيديو'
                                  : 'PLAYLIST • ${widget.items.length} VIDEOS',
                              style: AppTheme.microLabel(
                                isDark: isDark,
                                color: accent,
                                size: 8,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '$_completedCount/${widget.items.length}',
                            style: AppTheme.dataStyle(
                              isDark: isDark,
                              size: 11,
                              color: mutedClr,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (_anyDownloading)
                  _ControlButton(
                    icon: Icons.pause_rounded,
                    color:
                        isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
                    tooltip: isRtl ? 'إيقاف الكل' : 'Pause all',
                    onPressed: () {
                      triggerHaptic(settings);
                      for (final t in widget.items) {
                        if (t.status == DownloadStatus.downloading) {
                          provider.pauseTask(t.id);
                        }
                      }
                    },
                  )
                else if (!_allDone)
                  _ControlButton(
                    icon: Icons.play_arrow_rounded,
                    color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                    filled: true,
                    tooltip: isRtl ? 'استئناف الكل' : 'Resume all',
                    onPressed: () {
                      triggerHaptic(settings);
                      for (final t in widget.items) {
                        if (t.status == DownloadStatus.paused ||
                            t.status == DownloadStatus.queued) {
                          provider.resumeTask(t.id);
                        }
                      }
                    },
                  ),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: AppTheme.motionBase,
                  child: Icon(
                    Icons.keyboard_arrow_up_rounded,
                    size: 20,
                    color: mutedClr,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Aggregate progress + total percentage
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Stack(
                      children: [
                        Container(
                          height: 6,
                          decoration: AppTheme.progressTrack(isDark: isDark),
                        ),
                        AnimatedFractionallySizedBox(
                          widthFactor: _overallProgress,
                          duration: const Duration(milliseconds: 400),
                          curve: AppTheme.motionCurve,
                          child: Container(
                            height: 6,
                            decoration: AppTheme.progressFill(accent),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${(_overallProgress * 100).toStringAsFixed(1)}%',
                  style: AppTheme.dataStyle(
                    isDark: isDark,
                    size: 15,
                    weight: FontWeight.w800,
                    color: accent,
                  ),
                ),
              ],
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  children: [
                    Divider(
                      color: isDark
                          ? AppTheme.borderSubtle
                          : AppTheme.lightBorderSubtle,
                      height: 1,
                    ),
                    const SizedBox(height: 10),
                    ...widget.items.map(
                      (t) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _MediaCard(task: t, compact: true),
                      ),
                    ),
                  ],
                ),
              ),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: AppTheme.motionBase,
              firstCurve: AppTheme.motionCurve,
              secondCurve: AppTheme.motionCurve,
              sizeCurve: AppTheme.motionCurve,
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Advanced Controls (Long Press)
// ────────────────────────────────────────────────────────────────────────────

void _showAdvancedControls(
  BuildContext context,
  DownloadTask task,
  SettingsProvider settings,
) {
  final isDark = settings.isDarkMode;
  final provider = context.read<DownloadProvider>();
  final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
  final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) {
      return Container(
        decoration: BoxDecoration(
          color: isDark ? AppTheme.surface : AppTheme.lightSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(
            color: AppTheme.accent(isDark).withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: secClr.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: Icon(
                  task.status == DownloadStatus.paused
                      ? Icons.play_arrow
                      : Icons.pause,
                  color: AppTheme.accent(isDark),
                ),
                title: Text(
                  task.status == DownloadStatus.paused ? 'Resume' : 'Pause',
                  style: TextStyle(color: textClr),
                ),
                onTap: () {
                  Navigator.pop(context);
                  if (task.status == DownloadStatus.paused) {
                    provider.resumeTask(task.id);
                  } else {
                    provider.pauseTask(task.id);
                  }
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.copy_rounded,
                  color: AppTheme.neonBlue,
                ),
                title: Text(
                  'Copy Download Link',
                  style: TextStyle(color: textClr),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  await Clipboard.setData(ClipboardData(text: task.url));
                  if (context.mounted) {
                    ThemedSnackbar.show(
                      context,
                      message: 'Link copied',
                      color: AppTheme.neonGreen,
                      icon: Icons.check,
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.link_rounded,
                  color: AppTheme.neonViolet,
                ),
                title: Text(
                  'Update Download Link',
                  style: TextStyle(color: textClr),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showUpdateLinkDialog(context, task, provider);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.folder_open_rounded,
                  color: AppTheme.neonGreen,
                ),
                title: Text(L10n.of(context, 'open_file_btn'),
                    style: TextStyle(color: textClr)),
                onTap: () async {
                  Navigator.pop(context);
                  if (task.localFilePath.isNotEmpty &&
                      !_openingTaskIds.contains(task.id)) {
                    _openingTaskIds.add(task.id);
                    try {
                      await openFile(context, task.localFilePath, settings);
                    } finally {
                      _openingTaskIds.remove(task.id);
                    }
                  }
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: AppTheme.neonRed,
                ),
                title: Text(L10n.of(context, 'delete_btn'),
                    style: TextStyle(color: textClr)),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDelete(context, task, provider);
                },
              ),
              if (task.isTorrent) ...[
                ListTile(
                  leading: const Icon(
                    Icons.info_outline_rounded,
                    color: AppTheme.neonAmber,
                  ),
                  title: Text(L10n.of(context, 'properties'),
                      style: TextStyle(color: textClr)),
                  onTap: () {
                    Navigator.pop(context);
                    _showTorrentProperties(context, task, settings);
                  },
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      );
    },
  );
}

void _showUpdateLinkDialog(
  BuildContext context,
  DownloadTask task,
  DownloadProvider provider,
) {
  final urlController = TextEditingController(text: task.url);
  showDialog(
    context: context,
    builder: (dialogCtx) => DmxDialog(
      title: L10n.of(dialogCtx, 'update_link'),
      icon: Icons.link_rounded,
      content: DmxTextField(
        controller: urlController,
        hintText: L10n.of(dialogCtx, 'enter_new_url'),
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx),
          child: Text(
            L10n.of(dialogCtx, 'cancel_btn'),
            style: const TextStyle(fontFamily: 'Space Grotesk'),
          ),
        ),
        const SizedBox(width: 8),
        DmxButton.filled(
          label: L10n.of(dialogCtx, 'update_btn'),
          onPressed: () async {
            Navigator.pop(dialogCtx);
            await provider.updateTaskUrlAndResume(
              task.id,
              urlController.text.trim(),
            );
          },
        ),
      ],
    ),
  );
}

// ────────────────────────────────────────────────────────────────────────────
// Torrent Properties Sheet
// ────────────────────────────────────────────────────────────────────────────

void _showTorrentProperties(
  BuildContext context,
  DownloadTask task,
  SettingsProvider settings,
) {
  final isDark = settings.isDarkMode;
  final provider = context.read<DownloadProvider>();
  final isRtl = L10n.isRtl(context);
  final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
  final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
  final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
  final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
  final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
  final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
  final amberClr = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;

  // Resolve live torrent stats.
  final torrentId = provider.providerTorrentIds[task.id];
  final TorrentUpdateInfo? stats =
      torrentId != null ? provider.providerLatestTorrentStats[torrentId] : null;

  final dlSpeed = task.speed;
  final ulSpeed =
      task.isTorrent ? provider.getTorrentUploadSpeed(task.id) : 0.0;
  final seeds = provider.getTorrentSeeds(task.id);
  final peers = provider.getTorrentPeers(task.id);

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) {
      return Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.surface : AppTheme.lightSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(
            color: AppTheme.accent(isDark).withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle bar
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: secClr.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Title
                Row(
                  children: [
                    Icon(Icons.info_outline_rounded, color: amberClr, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isRtl ? 'خصائص التورنت' : 'Torrent Properties',
                        style: TextStyle(
                          color: textClr,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // ── Basic Info ──────────────────────────────────────────────
                _sectionHeader(
                  isRtl ? 'المعلومات الأساسية' : 'BASIC INFO',
                  blueClr,
                  isDark,
                ),
                const SizedBox(height: 10),
                _propRow(
                  isRtl ? 'الاسم' : 'Name',
                  task.fileName,
                  textClr,
                  secClr,
                  isRtl,
                ),
                _propRow(
                  isRtl ? 'المسار' : 'Save Path',
                  task.savePath,
                  textClr,
                  secClr,
                  isRtl,
                  mono: true,
                ),
                _propRow(
                  isRtl ? 'الحجم الكلي' : 'Total Size',
                  formatBytes(task.resolvedFileSize),
                  textClr,
                  secClr,
                  isRtl,
                ),
                _propRow(
                  isRtl ? 'تم تحميل' : 'Downloaded',
                  formatBytes(task.displayDownloadedBytes),
                  textClr,
                  secClr,
                  isRtl,
                ),

                _propRow(
                  isRtl ? 'الفئة' : 'Category',
                  task.category.isNotEmpty ? task.category : '—',
                  textClr,
                  secClr,
                  isRtl,
                ),
                const SizedBox(height: 20),
                // ── Transfer Info ───────────────────────────────────────────
                _sectionHeader(
                  isRtl ? 'معلومات النقل' : 'TRANSFER INFO',
                  greenClr,
                  isDark,
                ),
                const SizedBox(height: 10),
                _propRow(
                  isRtl ? 'سرعة التحميل' : 'Download Speed',
                  '${formatBytes(dlSpeed)}/s',
                  textClr,
                  secClr,
                  isRtl,
                ),
                _propRow(
                  isRtl ? 'سرعة الرفع' : 'Upload Speed',
                  '${formatBytes(ulSpeed)}/s',
                  textClr,
                  secClr,
                  isRtl,
                ),
                _propRow(
                  isRtl ? 'المزرعون' : 'Seeds',
                  stats != null ? '${stats.numSeeds}' : '$seeds',
                  textClr,
                  secClr,
                  isRtl,
                ),
                _propRow(
                  isRtl ? 'الأقران' : 'Peers',
                  stats != null ? '${stats.numPeers}' : '$peers',
                  textClr,
                  secClr,
                  isRtl,
                ),
                const SizedBox(height: 20),
                // ── Technical Info ──────────────────────────────────────────
                _sectionHeader(
                  isRtl ? 'المعلومات التقنية' : 'TECHNICAL INFO',
                  violetClr,
                  isDark,
                ),
                const SizedBox(height: 10),
                if (stats != null) ...[
                  if (stats.piecesTotal > 0)
                    _propRow(
                      isRtl ? 'القطع المكتملة' : 'Pieces',
                      '${stats.piecesHave} / ${stats.piecesTotal}',
                      textClr,
                      secClr,
                      isRtl,
                    ),
                  _propRow(
                    isRtl ? 'المُتتبع' : 'Current Tracker',
                    stats.currentTracker.isNotEmpty
                        ? stats.currentTracker
                        : '—',
                    textClr,
                    secClr,
                    isRtl,
                    mono: true,
                  ),
                  _propRow(
                    isRtl ? 'النسخ الموزعة' : 'Distributed Copies',
                    stats.distributedCopies.toStringAsFixed(2),
                    textClr,
                    secClr,
                    isRtl,
                  ),
                  _propRow(
                    isRtl ? 'الإعلان التالي' : 'Next Announce',
                    stats.nextAnnounceSeconds > 0
                        ? '${stats.nextAnnounceSeconds}s'
                        : '—',
                    textClr,
                    secClr,
                    isRtl,
                  ),
                ] else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      isRtl
                          ? 'لا توجد بيانات مباشرة (التورنت غير نشط)'
                          : 'No live data available (torrent is not active)',
                      style: TextStyle(color: mutedClr, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Widget _sectionHeader(String label, Color accentColor, bool isDark) {
  return Row(
    children: [
      Container(
        width: 3,
        height: 14,
        decoration: BoxDecoration(
          color: accentColor,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 8),
      Text(
        label,
        style: AppTheme.microLabel(
          isDark: isDark,
          size: 10,
        ).copyWith(color: accentColor, letterSpacing: 1.2),
      ),
    ],
  );
}

Widget _propRow(
  String label,
  String value,
  Color textClr,
  Color secClr,
  bool isRtl, {
  bool mono = false,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(label, style: TextStyle(color: secClr, fontSize: 12)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: textClr,
              fontSize: 12,
              fontFamily: mono ? 'monospace' : null,
            ),
            textAlign: isRtl ? TextAlign.right : TextAlign.left,
          ),
        ),
      ],
    ),
  );
}

final Set<String> _openingTaskIds = {};

void _confirmDelete(
  BuildContext context,
  DownloadTask task,
  DownloadProvider provider,
) async {
  final settings = context.read<SettingsProvider>();
  // Reuse the shared dialog (with the "also delete files from disk"
  // checkbox) instead of a bare Cancel/Delete confirm — otherwise deleting
  // from this menu silently never removed files on disk, unlike the card's
  // own delete button.
  final deleteFiles = await showDeleteConfirmationDialog(
    context,
    task,
    settings,
  );
  if (deleteFiles != null) {
    unawaited(provider.deleteTask(task.id, deleteFiles: deleteFiles));
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Delete confirmation (shared)
// ────────────────────────────────────────────────────────────────────────────

Future<bool?> showDeleteConfirmationDialog(
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
                      .withValues(alpha: 0.95),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: isDark
                      ? AppTheme.borderStrong
                      : AppTheme.lightBorderStrong,
                  width: 0.8,
                ),
              ),
              title: Text(
                L10n.of(context, 'delete_title'),
                style: TextStyle(
                  color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
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
                        ? 'هل أنت متأكد من حذف "${task.fileName}" من القائمة؟'
                        : 'Remove "${task.fileName}" from the list?',
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textSecondary
                          : AppTheme.lightTextSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: Checkbox(
                          value: deleteFiles,
                          activeColor:
                              isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                          onChanged: (val) =>
                              setState(() => deleteFiles = val ?? false),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: GestureDetector(
                          onTap: () =>
                              setState(() => deleteFiles = !deleteFiles),
                          child: Text(
                            L10n.of(context, 'delete_files_label'),
                            style: TextStyle(
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

class _CardSparklineGraph extends StatelessWidget {
  final List<double> history;
  final Color color;
  final double width;

  const _CardSparklineGraph({
    required this.history,
    required this.color,
    this.width = 80.0,
  });

  @override
  Widget build(BuildContext context) {
    if (PerformanceMonitor.shouldReduceMotion ||
        MediaQuery.disableAnimationsOf(context)) {
      return SizedBox(height: 24, width: width);
    }
    return RepaintBoundary(
      child: SizedBox(
        height: 24,
        width: width,
        child: CustomPaint(
          painter: _SparklinePainter(history, color),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> history;
  final Color color;

  _SparklinePainter(this.history, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (history.length < 2) return;
    final maxSpeed = history.reduce((a, b) => a > b ? a : b);
    if (maxSpeed <= 0) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    final stepX = size.width / (history.length - 1);

    for (int i = 0; i < history.length; i++) {
      final x = i * stepX;
      final y = size.height - ((history[i] / maxSpeed) * (size.height - 4) + 2);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) => true;
}

class _SiteBadge extends StatelessWidget {
  final String name;
  final bool isDark;

  const _SiteBadge({required this.name, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: isDark ? Colors.white24 : Colors.black12,
          width: 0.5,
        ),
      ),
      child: Text(
        name.toUpperCase(),
        style: TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
          color: isDark ? Colors.white70 : Colors.black54,
        ),
      ),
    );
  }
}
