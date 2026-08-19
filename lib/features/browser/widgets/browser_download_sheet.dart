import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/url_utils.dart';
import '../../../shared/mixins/pausable_loop_animation.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/browser_detector.dart';
import '../services/long_press_parser.dart';

// FIX(D1): Removed unused DownloadOptions class — nothing referenced it.

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
  final VoidCallback? onOpen;
  final VoidCallback? onOpenInBackground;
  final VoidCallback? onOpenInNewTab;
  final VoidCallback? onOpenInIncognito;
  final List<MediaSourceItem> sources;

  const BrowserDownloadSheet({
    super.key,
    required this.url,
    this.type,
    this.text,
    this.suggestedName,
    this.onQuality,
    this.downloadPageUrl,
    this.onOpen,
    this.onOpenInBackground,
    this.onOpenInNewTab,
    this.onOpenInIncognito,
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
    VoidCallback? onOpen,
    VoidCallback? onOpenInBackground,
    VoidCallback? onOpenInNewTab,
    VoidCallback? onOpenInIncognito,
    List<MediaSourceItem> sources = const [],
  }) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    HapticHelper.triggerHaptic(settings);
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
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
        onOpen: onOpen,
        onOpenInBackground: onOpenInBackground,
        onOpenInNewTab: onOpenInNewTab,
        onOpenInIncognito: onOpenInIncognito,
        sources: sources,
      ),
    );
  }

  @override
  State<BrowserDownloadSheet> createState() => _BrowserDownloadSheetState();
}

class _BrowserDownloadSheetState extends State<BrowserDownloadSheet>
    with
        SingleTickerProviderStateMixin,
        HapticHelper,
        WidgetsBindingObserver,
        PausableLoopAnimation<BrowserDownloadSheet> {
  bool _isSubmitting = false;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  @override
  AnimationController get loopController => _pulse;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) startPausableLoop();
    });
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
        child: Container(
          decoration: BoxDecoration(
            color: isDark
                ? (settings.isAmoledMode
                    ? AppTheme.amoledSurface
                    : AppTheme.surface)
                : AppTheme.lightSurface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(28),
            ),
            border: Border(
              top: BorderSide(
                  color: isDark && settings.isAmoledMode
                      ? AppTheme.amoledBorder
                      : accent.withValues(alpha: 0.4),
                  width: 1),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              // FIX-M10: Include keyboard padding to prevent layout overflow
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                20 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: SingleChildScrollView(
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
                                        color: accent.withValues(alpha: 0.18),
                                        blurRadius: 10,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Opacity(
                              opacity:
                                  (0.7 + _pulse.value * 0.3).clamp(0.0, 1.0),
                              child: Icon(_icon, color: accent, size: 22),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isRtl ? 'إشارة تحميل مرصودة' : 'SIGNAL LOCKED',
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
                    // ── Filename, Host & URL readout with corner brackets (U5) ───────────
                    Builder(
                      builder: (context) {
                        final detected = BrowserDetector.detect(widget.url);
                        final displayName = widget.suggestedName ??
                            detected?.suggestedFileName ??
                            fileNameFromUrl(widget.url);
                        final host = Uri.tryParse(widget.url)?.host ?? '';

                        return _CornerFrame(
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
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  displayName,
                                  style: TextStyle(
                                    color: textClr,
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (host.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Icon(Icons.language_rounded,
                                          size: 12, color: muted),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          host,
                                          style: TextStyle(
                                            color: muted,
                                            fontSize: 11,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        isRtl
                                            ? 'الحجم: غير معروف'
                                            : 'Size: Unknown',
                                        style: TextStyle(
                                          color: muted,
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 20),
                    // ── Link Navigation Actions ────────────────────
                    if (widget.onOpen != null ||
                        widget.onOpenInBackground != null ||
                        widget.onOpenInNewTab != null ||
                        widget.onOpenInIncognito != null) ...[
                      // Row 1: Open + Open in background
                      if (widget.onOpen != null ||
                          widget.onOpenInBackground != null) ...[
                        Row(
                          children: [
                            if (widget.onOpen != null)
                              Expanded(
                                child: _SheetButton(
                                  label: isRtl ? 'فتح' : 'OPEN',
                                  isDark: isDark,
                                  filled: false,
                                  accent: accent,
                                  onTap: () {
                                    Navigator.pop(context);
                                    widget.onOpen!();
                                  },
                                ),
                              ),
                            if (widget.onOpen != null &&
                                widget.onOpenInBackground != null)
                              const SizedBox(width: 10),
                            if (widget.onOpenInBackground != null)
                              Expanded(
                                child: _SheetButton(
                                  label:
                                      isRtl ? 'فتح في الخلفية' : 'OPEN IN BG',
                                  isDark: isDark,
                                  filled: false,
                                  accent: accent,
                                  onTap: () {
                                    Navigator.pop(context);
                                    widget.onOpenInBackground!();
                                  },
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                      ],
                      // Row 2: Open in new tab + Open in incognito
                      if (widget.onOpenInNewTab != null ||
                          widget.onOpenInIncognito != null) ...[
                        Row(
                          children: [
                            if (widget.onOpenInNewTab != null)
                              Expanded(
                                child: _SheetButton(
                                  label: isRtl
                                      ? 'فتح في علامة تبويب جديدة'
                                      : 'OPEN IN NEW TAB',
                                  isDark: isDark,
                                  filled: false,
                                  accent: accent,
                                  onTap: () {
                                    Navigator.pop(context);
                                    widget.onOpenInNewTab!();
                                  },
                                ),
                              ),
                            if (widget.onOpenInNewTab != null &&
                                widget.onOpenInIncognito != null)
                              const SizedBox(width: 10),
                            if (widget.onOpenInIncognito != null)
                              Expanded(
                                child: _SheetButton(
                                  label: isRtl
                                      ? 'فتح في التصفح الخفي'
                                      : 'OPEN IN INCOGNITO',
                                  isDark: isDark,
                                  filled: false,
                                  accent: accent,
                                  onTap: () {
                                    Navigator.pop(context);
                                    widget.onOpenInIncognito!();
                                  },
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                      ],
                      const SizedBox(height: 4),
                    ],
                    // ── Additional sources (long-press multi-source) ──
                    if (widget.sources.isNotEmpty) ...[
                      Text(
                        isRtl ? 'المصادر' : 'SOURCES',
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
                            label: isRtl ? 'إغلاق' : 'DISMISS',
                            isDark: isDark,
                            filled: false,
                            accent: accent,
                            onTap: () => Navigator.pop(context),
                          ),
                        ),
                        if (widget.onQuality != null) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: _SheetButton(
                              label: isRtl ? 'الجودة' : 'QUALITY',
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
                            label: isRtl ? 'تحميل' : 'DOWNLOAD',
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
        Navigator.of(context).pop();
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
                ? 'تم بدء التنزيل: $finalFileName'
                : 'Started downloading: $finalFileName',
            color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
            icon: Icons.file_download_done_rounded,
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
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
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
