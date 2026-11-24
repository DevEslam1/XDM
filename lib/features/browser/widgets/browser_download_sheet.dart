import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/url_utils.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/mixins/pausable_loop_animation.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/browser_detector.dart';
import '../services/long_press_parser.dart';

/// Detected-media and download capture bottom sheet shown when the browser
/// sniffer or long-press parser locks onto a downloadable resource.
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
    return showDmxModalBottomSheet<void>(
      context: context,
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
    switch (widget.type) {
      case 'video':
        return 'VIDEO';
      case 'audio':
        return 'AUDIO';
      case 'image':
        return 'IMAGE';
    }
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
        switch (_kind) {
          case DetectedMediaKind.video:
            return isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
          case DetectedMediaKind.audio:
            return isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
          case DetectedMediaKind.image:
            return isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
          default:
            return isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
        }
    }
  }

  void _copyUrl(BuildContext context, SettingsProvider settings, String url) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = _accentColor(isDark);
    Clipboard.setData(ClipboardData(text: url));
    HapticHelper.triggerHaptic(settings);
    ThemedSnackbar.show(
      context,
      message: isRtl ? 'تم نسخ الرابط' : 'Link copied',
      color: accent,
      icon: Icons.copy_rounded,
      isDarkMode: isDark,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isAmoled = settings.isAmoledMode;
    final isRtl = L10n.isRtl(context);
    final accent = _accentColor(isDark);
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textSecondary = AppTheme.textSecondaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);

    final detected = BrowserDetector.detect(widget.url);
    final displayName = (widget.suggestedName?.isNotEmpty ?? false)
        ? widget.suggestedName!
        : (detected?.suggestedFileName ?? fileNameFromUrl(widget.url));
    final host = Uri.tryParse(widget.url)?.host ?? '';
    final ext = p.extension(displayName).replaceFirst('.', '').toUpperCase();

    final hasNavActions = widget.onOpen != null ||
        widget.onOpenInBackground != null ||
        widget.onOpenInNewTab != null ||
        widget.onOpenInIncognito != null;

    return Directionality(
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: DmxSheetContainer(
        scrollable: true,
        isDark: isDark,
        isAmoled: isAmoled,
        accentColor: accent,
        header: DmxSheetHeader(
          isDark: isDark,
          accentColor: accent,
          title: isRtl ? 'إشارة تحميل مرصودة' : 'SIGNAL LOCKED',
          leading: AnimatedBuilder(
            animation: _pulse,
            builder: (context, child) => Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: isDark ? 0.14 : 0.10),
                borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
                border: Border.all(
                  color: accent.withValues(
                    alpha: 0.25 + _pulse.value * 0.25,
                  ),
                  width: DmxTokens.borderHairline,
                ),
                boxShadow: settings.enableGlow
                    ? [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.16),
                          blurRadius: 10,
                        ),
                      ]
                    : null,
              ),
              child: Icon(_icon, color: accent, size: 20),
            ),
          ),
          trailing: _TypePill(
            label: _kindLabel(),
            accent: accent,
            isDark: isDark,
            pulse: _pulse,
          ),
        ),
        footer:
            _buildFooter(context, settings, isDark, isAmoled, isRtl, accent),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Detected file readout card
            DmxSheetSection(
              isDark: isDark,
              isAmoled: isAmoled,
              elevated: true,
              accentColor: accent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          displayName,
                          style: TextStyle(
                            fontFamily: AppTheme.fontDisplay,
                            color: textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            height: 1.3,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: isRtl ? 'نسخ الرابط' : 'Copy URL',
                        child: InkWell(
                          onTap: () => _copyUrl(context, settings, widget.url),
                          borderRadius:
                              BorderRadius.circular(DmxTokens.radiusSm),
                          child: Container(
                            width: 34,
                            height: 34,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppTheme.panelBg(
                                isDark,
                                isAmoled: isAmoled,
                              ),
                              borderRadius:
                                  BorderRadius.circular(DmxTokens.radiusSm),
                              border: Border.all(
                                color: AppTheme.hairlineBorder(
                                  isDark,
                                  isAmoled: isAmoled,
                                ),
                                width: DmxTokens.borderThin,
                              ),
                            ),
                            child: Icon(
                              Icons.copy_rounded,
                              size: 16,
                              color: textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if ((widget.text ?? '').isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      widget.text!,
                      style: TextStyle(
                        fontFamily: AppTheme.fontBody,
                        color: textSecondary,
                        fontSize: 12,
                        height: 1.35,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (host.isNotEmpty)
                        _MetaPill(
                          icon: Icons.language_rounded,
                          label: host,
                          isDark: isDark,
                          isAmoled: isAmoled,
                        ),
                      if (ext.isNotEmpty && ext.length <= 6)
                        _MetaPill(
                          label: ext,
                          accent: accent,
                          isDark: isDark,
                          isAmoled: isAmoled,
                        ),
                      _MetaPill(
                        icon: Icons.data_usage_rounded,
                        label: isRtl ? 'الحجم: غير معروف' : 'Size: Unknown',
                        isDark: isDark,
                        isAmoled: isAmoled,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Multi-source list (when long-press parser returns variants)
            if (widget.sources.isNotEmpty) ...[
              const SizedBox(height: DmxTokens.sheetSectionGap),
              DmxSheetSection(
                title: isRtl ? 'المصادر' : 'SOURCES',
                isDark: isDark,
                isAmoled: isAmoled,
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < widget.sources.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          thickness: DmxTokens.borderThin,
                          color: AppTheme.hairlineBorder(
                            isDark,
                            isAmoled: isAmoled,
                          ),
                        ),
                      _SourceTile(
                        source: widget.sources[i],
                        accent: accent,
                        isDark: isDark,
                        isAmoled: isAmoled,
                        onTap: () => _startDownload(
                          context,
                          settings,
                          source: widget.sources[i],
                        ),
                        onCopy: () => _copyUrl(
                          context,
                          settings,
                          widget.sources[i].url,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],

            // Link Navigation Actions
            if (hasNavActions) ...[
              const SizedBox(height: DmxTokens.sheetSectionGap),
              DmxSheetSection(
                title: isRtl ? 'خيارات التصفح' : 'NAVIGATION',
                isDark: isDark,
                isAmoled: isAmoled,
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.onOpen != null ||
                        widget.onOpenInBackground != null) ...[
                      Row(
                        children: [
                          if (widget.onOpen != null)
                            Expanded(
                              child: _NavActionButton(
                                icon: Icons.open_in_browser_rounded,
                                label: isRtl ? 'فتح' : 'OPEN',
                                isDark: isDark,
                                isAmoled: isAmoled,
                                accent: accent,
                                onTap: () {
                                  Navigator.pop(context);
                                  widget.onOpen!();
                                },
                              ),
                            ),
                          if (widget.onOpen != null &&
                              widget.onOpenInBackground != null)
                            const SizedBox(width: 8),
                          if (widget.onOpenInBackground != null)
                            Expanded(
                              child: _NavActionButton(
                                icon: Icons.tab_unselected_rounded,
                                label: isRtl ? 'فتح في الخلفية' : 'OPEN IN BG',
                                isDark: isDark,
                                isAmoled: isAmoled,
                                accent: accent,
                                onTap: () {
                                  Navigator.pop(context);
                                  widget.onOpenInBackground!();
                                },
                              ),
                            ),
                        ],
                      ),
                      if (widget.onOpenInNewTab != null ||
                          widget.onOpenInIncognito != null)
                        const SizedBox(height: 8),
                    ],
                    if (widget.onOpenInNewTab != null ||
                        widget.onOpenInIncognito != null)
                      Row(
                        children: [
                          if (widget.onOpenInNewTab != null)
                            Expanded(
                              child: _NavActionButton(
                                icon: Icons.tab_rounded,
                                label: isRtl
                                    ? 'فتح في علامة تبويب جديدة'
                                    : 'OPEN IN NEW TAB',
                                isDark: isDark,
                                isAmoled: isAmoled,
                                accent: accent,
                                onTap: () {
                                  Navigator.pop(context);
                                  widget.onOpenInNewTab!();
                                },
                              ),
                            ),
                          if (widget.onOpenInNewTab != null &&
                              widget.onOpenInIncognito != null)
                            const SizedBox(width: 8),
                          if (widget.onOpenInIncognito != null)
                            Expanded(
                              child: _NavActionButton(
                                icon: Icons.visibility_off_rounded,
                                label: isRtl
                                    ? 'فتح في التصفح الخفي'
                                    : 'OPEN IN INCOGNITO',
                                isDark: isDark,
                                isAmoled: isAmoled,
                                accent: accent,
                                onTap: () {
                                  Navigator.pop(context);
                                  widget.onOpenInIncognito!();
                                },
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ],

            if (widget.url.isEmpty && widget.sources.isEmpty) ...[
              const SizedBox(height: 12),
              Text(
                isRtl
                    ? 'لم يتم العثور على رابط صالح للتحميل'
                    : 'No downloadable URL detected.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: AppTheme.fontBody,
                  fontSize: 12,
                  color: textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(
    BuildContext context,
    SettingsProvider settings,
    bool isDark,
    bool isAmoled,
    bool isRtl,
    Color accent,
  ) {
    if (widget.onQuality == null) {
      return DmxSheetActionBar(
        isDark: isDark,
        isAmoled: isAmoled,
        secondaryLabel: isRtl ? 'إغلاق' : 'DISMISS',
        onSecondary: () => Navigator.pop(context),
        primaryLabel: isRtl ? 'تحميل' : 'DOWNLOAD',
        primaryIcon: Icons.download_rounded,
        primaryColor: accent,
        primaryLoading: _isSubmitting,
        onPrimary: () => _startDownload(context, settings),
      );
    }

    final borderClr = AppTheme.hairlineBorder(
      isDark,
      isAmoled: isAmoled,
      strong: true,
    );
    final primaryFg = AppTheme.inkOn(accent);

    return DmxSheetActionBar(
      isDark: isDark,
      isAmoled: isAmoled,
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => Navigator.pop(context),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              foregroundColor: AppTheme.textPrimaryOf(isDark),
              side: BorderSide(color: borderClr, width: 1.0),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
              ),
            ),
            child: Text(
              isRtl ? 'إغلاق' : 'DISMISS',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: AppTheme.fontDisplay,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        Expanded(
          child: OutlinedButton(
            onPressed: () {
              Navigator.pop(context);
              widget.onQuality!();
            },
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              foregroundColor: accent,
              backgroundColor: accent.withValues(alpha: isDark ? 0.10 : 0.08),
              side: BorderSide(color: accent.withValues(alpha: 0.4), width: 1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
              ),
            ),
            child: Text(
              isRtl ? 'الجودة' : 'QUALITY',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: AppTheme.fontDisplay,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        Expanded(
          flex: widget.type == 'video' ? 1 : 2,
          child: FilledButton(
            onPressed:
                _isSubmitting ? null : () => _startDownload(context, settings),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 48),
              backgroundColor: accent,
              foregroundColor: primaryFg,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
              ),
            ),
            child: _isSubmitting
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(primaryFg),
                    ),
                  )
                : Text(
                    isRtl ? 'تحميل' : 'DOWNLOAD',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _startDownload(
    BuildContext context,
    SettingsProvider settingsProvider, {
    MediaSourceItem? source,
  }) async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);
    try {
      final downloadProvider = Provider.of<DownloadProvider>(
        context,
        listen: false,
      );
      final isRtl = L10n.isRtl(context);
      final isDark = settingsProvider.isDarkMode;

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

class _TypePill extends StatelessWidget {
  final String label;
  final Color accent;
  final bool isDark;
  final Animation<double> pulse;

  const _TypePill({
    required this.label,
    required this.accent,
    required this.isDark,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: isDark ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
        border: Border.all(
          color: accent.withValues(alpha: isDark ? 0.30 : 0.24),
          width: DmxTokens.borderThin,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: pulse,
            builder: (context, child) => Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(
                  alpha: (0.55 + pulse.value * 0.45).clamp(0.0, 1.0),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontFamily: AppTheme.fontDisplay,
              fontSize: DmxTokens.textXs,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.7,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  final IconData? icon;
  final String label;
  final Color? accent;
  final bool isDark;
  final bool isAmoled;

  const _MetaPill({
    this.icon,
    required this.label,
    this.accent,
    required this.isDark,
    required this.isAmoled,
  });

  @override
  Widget build(BuildContext context) {
    final fg = accent ?? AppTheme.textSecondaryOf(isDark);
    final bg = accent != null
        ? accent!.withValues(alpha: isDark ? 0.14 : 0.10)
        : AppTheme.panelBg(isDark, isAmoled: isAmoled);
    final border = accent != null
        ? accent!.withValues(alpha: isDark ? 0.28 : 0.22)
        : AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
        border: Border.all(color: border, width: DmxTokens.borderThin),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AppTheme.fontBody,
                fontSize: DmxTokens.textXs,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isDark;
  final bool isAmoled;
  final Color accent;
  final VoidCallback onTap;

  const _NavActionButton({
    required this.icon,
    required this.label,
    required this.isDark,
    required this.isAmoled,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        child: Ink(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: AppTheme.surfaceColor(isDark, isAmoled: isAmoled),
            borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
            border: Border.all(
              color: AppTheme.hairlineBorder(isDark, isAmoled: isAmoled),
              width: DmxTokens.borderThin,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: accent),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    fontWeight: FontWeight.w700,
                    fontSize: DmxTokens.textXs,
                    letterSpacing: 0.4,
                    color: textPrimary,
                  ),
                ),
              ),
            ],
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
  final bool isAmoled;
  final VoidCallback onTap;
  final VoidCallback onCopy;

  const _SourceTile({
    required this.source,
    required this.accent,
    required this.isDark,
    required this.isAmoled,
    required this.onTap,
    required this.onCopy,
  });

  IconData _sourceIcon() {
    switch (source.type) {
      case 'video':
        return Icons.movie_outlined;
      case 'audio':
        return Icons.audiotrack_outlined;
      case 'image':
        return Icons.image_outlined;
      default:
        return Icons.link_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);
    final host = Uri.tryParse(source.url)?.host ?? '';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: isDark ? 0.14 : 0.10),
                  borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
                ),
                child: Icon(_sourceIcon(), color: accent, size: 16),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppTheme.fontDisplay,
                        color: textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (host.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AppTheme.fontBody,
                          color: textMuted,
                          fontSize: DmxTokens.textXs,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                onPressed: onCopy,
                icon: Icon(Icons.copy_rounded, size: 16, color: textMuted),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: EdgeInsets.zero,
              ),
              const SizedBox(width: 4),
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: isDark ? 0.14 : 0.10),
                  borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
                ),
                child: Icon(Icons.download_rounded, color: accent, size: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
