import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/url_utils.dart';
import '../../../shared/mixins/pausable_loop_animation.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/browser_detector.dart';
import '../services/long_press_parser.dart';

/// Signal-intercept console shown when the sniffer locks onto a downloadable
/// resource. Corner-bracket targeting frame, pulsing lock indicator, and a
/// monospace URL readout give it a distinct "capture" feel.
class BrowserDownloadSheet extends StatefulWidget {
  final String url;
  final String? type;
  final String? text;
  final String? suggestedName;
  final VoidCallback? onQuality;
  final String? downloadPageUrl;

  /// Additional discovered sources (alternative qualities/streams) for the
  /// long-pressed media. Each is offered as its own download tile.
  final List<MediaSourceItem> sources;

  const BrowserDownloadSheet({
    super.key,
    required this.url,
    this.type,
    this.text,
    this.suggestedName,
    this.onQuality,
    this.downloadPageUrl,
    this.sources = const [],
  });

  static Future<void> show(
    BuildContext context,
    String url, {
    String? type,
    String? text,
    String? suggestedName,
    VoidCallback? onQuality,
    String? downloadPageUrl,
    List<MediaSourceItem> sources = const [],
  }) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    runHaptic(settings);
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => BrowserDownloadSheet(
        url: url,
        type: type,
        text: text,
        suggestedName: suggestedName,
        onQuality: onQuality,
        downloadPageUrl: downloadPageUrl,
        sources: sources,
      ),
    );
  }

  @override
  State<BrowserDownloadSheet> createState() => _BrowserDownloadSheetState();
}

class _BrowserDownloadSheetState extends State<BrowserDownloadSheet>
    with SingleTickerProviderStateMixin, HapticHelper, WidgetsBindingObserver, PausableLoopAnimation<BrowserDownloadSheet> {


  bool _isSubmitting = false;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  AnimationController get loopController => _pulse;

  @override
  void initState() {
    super.initState();
    startPausableLoop();
  }

  @override
  void dispose() {
    stopPausableLoop();
    _pulse.dispose();
    super.dispose();
  }


  DetectedMediaKind get _kind =>
      BrowserDetector.detect(widget.url)?.kind ?? DetectedMediaKind.unknown;

  IconData get _icon {
    switch (widget.type) {
      case 'video':
        return Icons.movie_outlined;
      case 'audio':
        return Icons.audiotrack_outlined;
      case 'image':
        return Icons.image_outlined;
      default:
        switch (_kind) {
          case DetectedMediaKind.video:
            return Icons.movie_outlined;
          case DetectedMediaKind.audio:
            return Icons.audiotrack_outlined;
          case DetectedMediaKind.image:
            return Icons.image_outlined;
          case DetectedMediaKind.archive:
            return Icons.folder_zip_outlined;
          case DetectedMediaKind.document:
            return Icons.description_outlined;
          case DetectedMediaKind.torrent:
          case DetectedMediaKind.magnet:
            return Icons.link_rounded;
          default:
            return Icons.insert_drive_file_outlined;
        }
    }
  }

  String _kindLabel() {
    switch (_kind) {
      case DetectedMediaKind.video:
        return 'VIDEO';
      case DetectedMediaKind.audio:
        return 'AUDIO';
      case DetectedMediaKind.image:
        return 'IMAGE';
      case DetectedMediaKind.document:
        return 'DOCUMENT';
      case DetectedMediaKind.archive:
        return 'ARCHIVE';
      case DetectedMediaKind.executable:
        return 'EXECUTABLE';
      case DetectedMediaKind.torrent:
        return 'TORRENT';
      case DetectedMediaKind.magnet:
        return 'MAGNET';
      default:
        return 'FILE';
    }
  }

  Color _accentColor(bool isDark) {
    switch (widget.type) {
      case 'video':
        return isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
      case 'audio':
        return isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
      case 'image':
        return isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
      default:
        return isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = _accentColor(isDark);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final muted = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return Directionality(
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: DmxBackdropFilter(
          sigmaX: 15,
          sigmaY: 15,
          child: Container(
            decoration: BoxDecoration(
              color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                  .withValues(alpha: 0.92),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              border: Border(
                top: BorderSide(color: accent.withValues(alpha: 0.4), width: 1),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 18),
                        decoration: BoxDecoration(
                          color: muted.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    // ── Signal lock header ─────────────────────────
                    Row(
                      children: [
                        AnimatedBuilder(
                          animation: _pulse,
                          builder: (context, child) => Container(
                            padding: const EdgeInsets.all(11),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: accent.withValues(
                                  alpha: 0.3 + _pulse.value * 0.3,
                                ),
                              ),
                              boxShadow: settings.enableGlow
                                  ? [
                                      BoxShadow(
                                        color: accent.withValues(
                                          alpha: 0.15 + _pulse.value * 0.2,
                                        ),
                                        blurRadius: 12,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Icon(_icon, color: accent, size: 22),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isRtl
                                    ? 'Ø¥Ø´Ø§Ø±Ø© ØªØ­Ù…ÙŠÙ„ Ù…Ø±ØµÙˆØ¯Ø©'
                                    : 'SIGNAL LOCKED',
                                style: TextStyle(
                                  fontFamily: 'Space Grotesk',
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                  letterSpacing: 1.2,
                                  color: accent,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  AnimatedBuilder(
                                    animation: _pulse,
                                    builder: (context, child) => Container(
                                      width: 5,
                                      height: 5,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: accent,
                                        boxShadow: [
                                          BoxShadow(
                                            color: accent.withValues(
                                              alpha: 0.3 + _pulse.value * 0.5,
                                            ),
                                            blurRadius: 4,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _kindLabel(),
                                    style: TextStyle(
                                      fontFamily: 'Space Grotesk',
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.5,
                                      color: muted,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if ((widget.text ?? '').isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        widget.text!,
                        style: TextStyle(color: secClr, fontSize: 12),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 14),
                    // ── URL readout with corner brackets ───────────
                    _CornerFrame(
                      color: accent,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: (isDark
                                  ? AppTheme.background
                                  : AppTheme.lightBackground)
                              .withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          widget.url,
                          style: TextStyle(
                            color: textClr,
                            fontSize: 11,
                            fontFamily: 'monospace',
                            height: 1.4,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    // ── Additional sources (long-press multi-source) ──
                    if (widget.sources.isNotEmpty) ...[
                      Text(
                        isRtl ? 'Ø§Ù„Ù…ØµØ§Ø¯Ø±' : 'SOURCES',
                        style: TextStyle(
                          fontFamily: 'Space Grotesk',
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                          color: muted,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...widget.sources.map(
                        (source) => _SourceTile(
                          source: source,
                          accent: accent,
                          isDark: isDark,
                          onTap: () =>
                              _startDownload(context, settings, source: source),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    // ── Actions ────────────────────────────────────
                    Row(
                      children: [
                        Expanded(
                          child: _SheetButton(
                            label: isRtl ? 'Ø¥ØºÙ„Ø§Ø¡' : 'DISMISS',
                            isDark: isDark,
                            filled: false,
                            accent: accent,
                            onTap: () => Navigator.pop(context),
                          ),
                        ),
                        if (widget.type == 'video' &&
                            widget.onQuality != null) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: _SheetButton(
                              label: isRtl ? 'Ø§Ù„Ø¬ÙˆØ¯Ø©' : 'QUALITY',
                              isDark: isDark,
                              filled: false,
                              accent: accent,
                              onTap: () {
                                Navigator.pop(context);
                                widget.onQuality!();
                              },
                            ),
                          ),
                        ],
                        const SizedBox(width: 10),
                        Expanded(
                          flex: widget.type == 'video' ? 1 : 2,
                          child: _SheetButton(
                            label: isRtl ? 'ØªØ­Ù…ÙŠÙ„' : 'DOWNLOAD',
                            isDark: isDark,
                            filled: true,
                            accent: accent,
                            onTap: () => _startDownload(context, settings),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _startDownload(
    BuildContext context,
    SettingsProvider settingsProvider, {
    MediaSourceItem? source,
  }) async {
    if (_isSubmitting) return;
    _isSubmitting = true;
    try {
      final downloadProvider = Provider.of<DownloadProvider>(
        context,
        listen: false,
      );
      final isRtl = L10n.isRtl(context);
      final isDark = settingsProvider.isDarkMode;

      // When downloading a specific source, prefer its URL/type over the
      // sheet's defaults.
      final targetUrl = source?.url ?? widget.url;
      final targetType = source?.type ?? widget.type;

      // 1. Deduplicate by URL
      final existing =
          downloadProvider.tasks.where((t) => t.url == targetUrl).toList();
      if (existing.isNotEmpty) {
        final task = existing.first;
        if (task.status == DownloadStatus.completed) {
          ThemedSnackbar.show(
            context,
            message: isRtl
                ? 'هذا التنزيل مكتمل بالفعل'
                : 'This download is already completed.',
            color: AppTheme.neonGreen,
            icon: Icons.check_circle_outline,
            isDarkMode: isDark,
          );
        } else if (task.status == DownloadStatus.downloading ||
            task.status == DownloadStatus.queued) {
          ThemedSnackbar.show(
            context,
            message: isRtl
                ? 'هذا التنزيل قيد التشغيل بالفعل'
                : 'This download is already in progress.',
            color: AppTheme.neonBlue,
            icon: Icons.info_outline,
            isDarkMode: isDark,
          );
        } else {
          downloadProvider.resumeTask(task.id);
          ThemedSnackbar.show(
            context,
            message: isRtl ? 'تم استئناف التنزيل' : 'Download resumed.',
            color: AppTheme.neonBlue,
            icon: Icons.play_arrow,
            isDarkMode: isDark,
          );
        }
        if (context.mounted) Navigator.pop(context);
        return;
      }

      // 2. Resolve filename
      String finalFileName = widget.suggestedName ?? '';
      if (finalFileName.isEmpty) {
        finalFileName = targetUrl.startsWith('magnet:')
            ? (parseMagnetUrl(targetUrl)['name'] ?? 'Torrent Download')
            : fileNameFromUrl(targetUrl);
      }

      // 3. Deduplicate name
      String numbered = finalFileName;
      final ext = p.extension(finalFileName);
      final base = p.basenameWithoutExtension(finalFileName);
      var counter = 1;
      final existingNames =
          downloadProvider.tasks.map((t) => t.fileName.toLowerCase()).toSet();
      while (existingNames.contains(numbered.toLowerCase())) {
        numbered = '${base}_$counter$ext';
        counter++;
      }
      finalFileName = numbered;

      // 4. Category
      String category;
      if (targetType == 'video') {
        category = 'Video';
      } else if (targetType == 'audio') {
        category = 'Audio';
      } else if (targetType == 'image') {
        category = 'Image';
      } else {
        category = categoryFromFileName(finalFileName);
      }

      // 5. Fire
      await downloadProvider.addDownload(
        name: finalFileName,
        url: targetUrl,
        size: 0,
        category: category,
        savePath: '',
        downloadPageUrl: widget.downloadPageUrl,
      );
      if (context.mounted) {
        if (downloadProvider.lastError != null) {
          ThemedSnackbar.show(
            context,
            message: downloadProvider.lastError!,
            color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
            icon: Icons.error_outline,
            isDarkMode: isDark,
          );
        } else {
          ThemedSnackbar.show(
            context,
            message: isRtl
                ? 'تم إنشاء الاتصال. القنوات متصلة.'
                : 'TRANSMISSION ESTABLISHED. CHANNELS CONNECTED.',
            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            icon: Icons.rocket_launch_outlined,
            isDarkMode: isDark,
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ThemedSnackbar.show(
          context,
          message: e.toString(),
          color: settingsProvider.isDarkMode
              ? AppTheme.neonRed
              : AppTheme.lightNeonRed,
          icon: Icons.error_outline,
          isDarkMode: settingsProvider.isDarkMode,
        );
      }
    } finally {
      _isSubmitting = false;
    }
    if (context.mounted) Navigator.pop(context);
  }
}

/// Targeting-style corner brackets wrapping the URL readout.
class _CornerFrame extends StatelessWidget {
  final Color color;
  final Widget child;

  const _CornerFrame({required this.color, required this.child});

  @override
  Widget build(BuildContext context) {
    const len = 14.0;
    const thick = 2.0;
    Widget bracket({required bool top, required bool left}) {
      return CustomPaint(
        size: const Size(len, len),
        painter: _BracketPainter(color: color, top: top, left: left),
      );
    }

    return Stack(
      children: [
        Padding(padding: const EdgeInsets.all(6), child: child),
        Positioned(top: 0, left: 0, child: bracket(top: true, left: true)),
        Positioned(top: 0, right: 0, child: bracket(top: true, left: false)),
        Positioned(bottom: 0, left: 0, child: bracket(top: false, left: true)),
        Positioned(
          bottom: 0,
          right: 0,
          child: bracket(top: false, left: false),
        ),
        const SizedBox(width: thick, height: thick),
      ],
    );
  }
}

class _BracketPainter extends CustomPainter {
  final Color color;
  final bool top;
  final bool left;

  _BracketPainter({required this.color, required this.top, required this.left});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path();
    if (top && left) {
      path.moveTo(0, size.height);
      path.lineTo(0, 0);
      path.lineTo(size.width, 0);
    } else if (top && !left) {
      path.moveTo(0, 0);
      path.lineTo(size.width, 0);
      path.lineTo(size.width, size.height);
    } else if (!top && left) {
      path.moveTo(0, 0);
      path.lineTo(0, size.height);
      path.lineTo(size.width, size.height);
    } else {
      path.moveTo(size.width, 0);
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SheetButton extends StatelessWidget {
  final String label;
  final bool isDark;
  final bool filled;
  final Color accent;
  final VoidCallback onTap;

  const _SheetButton({
    required this.label,
    required this.isDark,
    required this.filled,
    required this.accent,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          height: 48,
          decoration: BoxDecoration(
            color: filled
                ? accent
                : accent.withValues(alpha: isDark ? 0.10 : 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: filled ? accent : accent.withValues(alpha: 0.4),
              width: filled ? 0 : 1,
            ),
            boxShadow: filled
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.3),
                      blurRadius: 14,
                      spreadRadius: -3,
                    ),
                  ]
                : null,
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Space Grotesk',
                fontWeight: FontWeight.w800,
                fontSize: 12,
                letterSpacing: 1,
                color: filled ? (isDark ? Colors.black : Colors.white) : accent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One downloadable source tile in the multi-source long-press sheet.
class _SourceTile extends StatelessWidget {
  final MediaSourceItem source;
  final Color accent;
  final bool isDark;
  final VoidCallback onTap;

  const _SourceTile({
    required this.source,
    required this.accent,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textPrimary =
        isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: (isDark ? AppTheme.glassBg : AppTheme.lightGlassBg)
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color:
                    isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                width: 0.6,
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.link_rounded, color: accent, size: 15),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    source.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(Icons.download_rounded, color: accent, size: 15),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
