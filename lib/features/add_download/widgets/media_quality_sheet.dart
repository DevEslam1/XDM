import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/design/dmx_design.dart';
import '../../settings/provider/settings_provider.dart';

class MediaQualitySheet extends StatefulWidget {
  final String videoUrl;
  final List<Map<String, dynamic>>? preloadedStreams;

  const MediaQualitySheet({
    super.key,
    required this.videoUrl,
    this.preloadedStreams,
  });

  static bool _isShowing = false;

  static Future<Map<String, dynamic>?> show(
    BuildContext context,
    String videoUrl, {
    List<Map<String, dynamic>>? preloadedStreams,
  }) async {
    if (_isShowing) return null;
    _isShowing = true;
    try {
      final settings = Provider.of<SettingsProvider>(context, listen: false);
      runHaptic(settings);
      if (!context.mounted) return null;
      return await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.1),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        builder: (_) => MediaQualitySheet(
          videoUrl: videoUrl,
          preloadedStreams: preloadedStreams,
        ),
      );
    } finally {
      _isShowing = false;
    }
  }

  @override
  State<MediaQualitySheet> createState() => _MediaQualitySheetState();
}

class _MediaQualitySheetState extends State<MediaQualitySheet> {
  List<Map<String, dynamic>> _streams = [];
  bool _isLoading = true;
  String? _errorMessage;
  int _selectedTabIndex = 0;

  @override
  void initState() {
    super.initState();
    if (widget.preloadedStreams != null &&
        widget.preloadedStreams!.isNotEmpty) {
      _streams = widget.preloadedStreams!;
      _isLoading = false;
    } else {
      _fetchStreams();
    }
  }

  Future<void> _fetchStreams() async {
    debugPrint('[MediaQualitySheet] Fetching streams for: ${widget.videoUrl}');
    try {
      await YoutubeService.fetchCookiesFromWebView();
      final streams = await YoutubeService.getStreamsForAnyUrl(widget.videoUrl);
      debugPrint(
        '[MediaQualitySheet] Received ${streams?.length ?? 0} streams',
      );
      if (!mounted) return;
      setState(() {
        _streams = streams ?? [];
        _isLoading = false;
        if (_streams.isEmpty) {
          _errorMessage = L10n.isRtl(context)
              ? 'لم يتم العثور على بث لهذا الرابط.'
              : 'No streams found for this URL.';
        }
      });
    } catch (e, st) {
      // FIX-4: Actionable error message for backend reachability and rate limits
      debugPrint('[MediaQualitySheet] Error fetching streams: $e\n$st');
      if (!mounted) return;
      final errorStr = e.toString().replaceAll('Exception: ', '');
      setState(() {
        _isLoading = false;
        if (errorStr.toLowerCase().contains('rate limit')) {
          _errorMessage = L10n.isRtl(context)
              ? 'تم الوصول إلى حد الطلبات. يرجى المحاولة لاحقاً.'
              : errorStr;
        } else if (errorStr.toLowerCase().contains('sign in') ||
            errorStr.toLowerCase().contains('bot') ||
            errorStr.toLowerCase().contains('confirm you\'re not a bot')) {
          _errorMessage = L10n.isRtl(context)
              ? 'يتطلب يوتيوب تسجيل الدخول لتأكيد أنك لست روبوت.\n\n'
                  'يرجى تسجيل الدخول في حساب يوتيوب عبر المتصفح ثم الضغط على إعادة المحاولة.'
              : 'YouTube requires sign-in to confirm you are not a bot.\n\n'
                  'Please sign in to YouTube in the browser view and tap Retry.';
        } else if (errorStr.contains('Cannot reach') ||
            errorStr.contains('backend') ||
            errorStr.contains('connection')) {
          _errorMessage = L10n.isRtl(context)
              ? 'تعذر الوصول إلى خادم الاستخراج.\n\n'
                  'الحلول الممكنة:\n'
                  '• تحقق من اتصال الإنترنت\n'
                  '• انتظر 30 ثانية (إقلاع الخادم البارد)\n'
                  '• الإعدادات ← الشبكة ← عنوان الخادم الخلفي ← تغيير'
              : 'Cannot reach the extraction backend.\n\n'
                  'Possible fixes:\n'
                  '• Check your internet connection\n'
                  '• Wait 30s (server cold start)\n'
                  '• Settings → Network → Backend URL → change it';
        } else {
          _errorMessage = L10n.isRtl(context)
              ? 'فشل جلب البث: $errorStr'
              : 'Failed to fetch streams: $errorStr';
        }
      });
    }
  }

  int _parseQuality(String q) {
    final match = RegExp(r'(\d+)').firstMatch(q);
    return match != null ? int.parse(match.group(1)!) : 0;
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'muxed':
        return Icons.ondemand_video_outlined;
      case 'audio':
        return Icons.audiotrack_outlined;
      case 'video_only':
        return Icons.videocam_outlined;
      case 'combined':
        return Icons.hd_outlined;
      default:
        return Icons.play_circle_outline;
    }
  }

  Color _colorForType(String type, bool isDark) {
    switch (type) {
      case 'muxed':
        return isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
      case 'audio':
        return isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
      case 'video_only':
        return isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
      case 'combined':
        return isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
      default:
        return isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final green = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final glassBorder =
        isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
    final panelBg = isDark ? const Color(0xFF0F0F16) : const Color(0xFFF1F5F9);

    final audio = _streams.where((s) => s['type'] == 'audio').toList()
      ..sort((a, b) {
        final aSize = a['size'] as int? ?? 0;
        final bSize = b['size'] as int? ?? 0;
        return bSize.compareTo(aSize);
      });

    final rawVideos = _streams
        .where((s) =>
            s['type'] == 'video_only' ||
            s['type'] == 'combined' ||
            s['type'] == 'muxed')
        .toList();

    final Map<int, Map<String, dynamic>> videosByHeight = {};
    for (final s in rawVideos) {
      final qStr = s['quality'] as String? ?? '';
      final h = _parseQuality(qStr);
      final key = h > 0 ? h : rawVideos.indexOf(s);

      if (!videosByHeight.containsKey(key)) {
        videosByHeight[key] = Map<String, dynamic>.from(s);
      } else {
        final existing = videosByHeight[key]!;
        final existingExt = (existing['ext'] as String? ?? '').toLowerCase();
        final currentExt = (s['ext'] as String? ?? '').toLowerCase();

        if (currentExt == 'mp4' && existingExt != 'mp4') {
          videosByHeight[key] = Map<String, dynamic>.from(s);
        } else if (existingExt == 'mp4' && currentExt != 'mp4') {
          // Keep existing MP4 stream
        } else {
          final existingSize = (existing['videoSize'] as int? ?? 0) > 0
              ? (existing['videoSize'] as int)
              : (existing['size'] as int? ?? 0);
          final currentSize = (s['videoSize'] as int? ?? 0) > 0
              ? (s['videoSize'] as int)
              : (s['size'] as int? ?? 0);
          if (currentSize > existingSize) {
            videosByHeight[key] = Map<String, dynamic>.from(s);
          }
        }
      }
    }

    final videoList = videosByHeight.entries.map((entry) {
      final h = entry.key;
      final v = entry.value;
      final vType = v['type'] as String? ?? 'muxed';

      if (audio.isNotEmpty &&
          (vType == 'video_only' ||
              v['audioSrc'] == null ||
              v['audioSrc'].toString().isEmpty)) {
        Map<String, dynamic> pairedAudio;
        if (h >= 720) {
          pairedAudio = audio.first;
        } else if (h == 480) {
          pairedAudio = audio[audio.length ~/ 2];
        } else {
          pairedAudio = audio.last;
        }

        final audioUrl = pairedAudio['src'] ??
            pairedAudio['direct_url'] ??
            pairedAudio['url'];
        final aSize = (pairedAudio['size'] as int? ?? 0) > 0
            ? (pairedAudio['size'] as int)
            : (pairedAudio['audioSize'] as int? ?? 0);
        final vSize = (v['videoSize'] as int? ?? 0) > 0
            ? (v['videoSize'] as int)
            : (v['size'] as int? ?? 0);

        v['audioSrc'] = audioUrl?.toString();
        v['videoSize'] = vSize;
        v['audioSize'] = aSize;
        v['size'] = vSize + aSize;
        v['type'] = 'combined';
        final qLabel = v['quality']?.toString() ?? '';
        v['label'] = qLabel.isNotEmpty ? '$qLabel MP4' : 'Video MP4';
      }
      return v;
    }).toList()
      ..sort((a, b) {
        final aHeight = _parseQuality(a['quality'] as String? ?? '');
        final bHeight = _parseQuality(b['quality'] as String? ?? '');
        return bHeight.compareTo(aHeight);
      });

    final videoTitle = _streams.isNotEmpty
        ? (_streams.first['title'] as String? ?? 'Media')
        : 'Media';

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      builder: (context, scrollController) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: DmxBackdropFilter(
            sigmaX: 15,
            sigmaY: 15,
            child: Container(
              decoration: BoxDecoration(
                color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                    .withValues(alpha: 0.95),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border(
                  top: BorderSide(
                    color: accent.withValues(alpha: 0.4),
                    width: 1.2,
                  ),
                ),
              ),
              child: Column(
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(top: 12, bottom: 8),
                      decoration: BoxDecoration(
                        color: mutedClr.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // ── Header ──
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Icon(
                            Icons.play_circle_filled,
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
                                L10n.of(context, 'yt_video_quality'),
                                style: TextStyle(
                                  color: accent,
                                  fontFamily: 'Space Grotesk',
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.0,
                                  fontSize: 14,
                                ),
                              ),
                              if (!_isLoading && _streams.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Text(
                                    videoTitle,
                                    style: TextStyle(
                                      color: secClr,
                                      fontSize: 11,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: _isLoading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  Icons.refresh_rounded,
                                  color: accent,
                                  size: 20,
                                ),
                          tooltip: L10n.of(context, 'retry_btn'),
                          onPressed: _isLoading
                              ? null
                              : () {
                                  setState(() {
                                    _isLoading = true;
                                    _errorMessage = null;
                                    _streams = [];
                                  });
                                  _fetchStreams();
                                },
                        ),
                      ],
                    ),
                  ),
                  // ── Legal banner ──
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 6,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.amber.withValues(alpha: 0.3),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.gavel_rounded,
                            size: 14,
                            color: Colors.amber,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              L10n.of(context, 'yt_legal_warning'),
                              style: TextStyle(color: secClr, fontSize: 10),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // ── Tabs with sliding indicator ──
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 4,
                    ),
                    child: Container(
                      height: 42,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: panelBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: glassBorder, width: 0.8),
                      ),
                      child: LayoutBuilder(
                        builder: (_, c) {
                          final half = c.maxWidth / 2;
                          return Stack(
                            children: [
                              AnimatedPositioned(
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOutCubic,
                                left: _selectedTabIndex == 0 ? 3 : half,
                                top: 3,
                                bottom: 3,
                                width: half - 6,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: (_selectedTabIndex == 0
                                            ? accent
                                            : green)
                                        .withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(9),
                                    border: Border.all(
                                      color: (_selectedTabIndex == 0
                                              ? accent
                                              : green)
                                          .withValues(alpha: 0.4),
                                    ),
                                  ),
                                ),
                              ),
                              Row(
                                children: [
                                  Expanded(
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () =>
                                          setState(() => _selectedTabIndex = 0),
                                      child: Center(
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.videocam_rounded,
                                              size: 14,
                                              color: _selectedTabIndex == 0
                                                  ? accent
                                                  : secClr,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              L10n.of(context, 'video_label'),
                                              style: TextStyle(
                                                color: _selectedTabIndex == 0
                                                    ? accent
                                                    : secClr,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 11,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () =>
                                          setState(() => _selectedTabIndex = 1),
                                      child: Center(
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.audiotrack_rounded,
                                              size: 14,
                                              color: _selectedTabIndex == 1
                                                  ? green
                                                  : secClr,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              L10n.of(context, 'audio_label'),
                                              style: TextStyle(
                                                color: _selectedTabIndex == 1
                                                    ? green
                                                    : secClr,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 11,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // ── Content ──
                  if (_isLoading)
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              L10n.of(context, 'fetching_streams'),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (_errorMessage != null)
                    Expanded(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.error_outline,
                                color: isDark
                                    ? AppTheme.neonRed
                                    : AppTheme.lightNeonRed,
                                size: 40,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _errorMessage!,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: secClr, fontSize: 12),
                              ),
                              const SizedBox(height: 20),
                              TextButton.icon(
                                onPressed: () {
                                  setState(() {
                                    _isLoading = true;
                                    _errorMessage = null;
                                    _streams = [];
                                  });
                                  _fetchStreams();
                                },
                                icon: Icon(
                                  Icons.refresh_rounded,
                                  size: 16,
                                  color: accent,
                                ),
                                label: Text(
                                  L10n.of(context, 'retry_btn'),
                                  style: TextStyle(
                                    color: accent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        children: [
                          if (_selectedTabIndex == 0) ...[
                            if (videoList.isNotEmpty) ...[
                              _sectionHeader(
                                context,
                                L10n.of(context, 'video_label'),
                                Icons.video_file_outlined,
                                isDark
                                    ? AppTheme.neonBlue
                                    : AppTheme.lightNeonBlue,
                                isDark,
                                trailing: _recommendBadge(isDark),
                              ),
                              ...videoList.map(
                                (s) =>
                                    _streamTile(context, s, isDark, settings),
                              ),
                              const SizedBox(height: 12),
                            ],
                            if (videoList.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(32),
                                child: Center(
                                  child: Text(
                                    'No video streams found.',
                                    style: TextStyle(
                                      color: secClr,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                          ] else ...[
                            if (audio.isNotEmpty) ...[
                              _sectionHeader(
                                context,
                                L10n.of(context, 'audio_label'),
                                Icons.audiotrack_outlined,
                                green,
                                isDark,
                              ),
                              ...audio.map(
                                (s) =>
                                    _streamTile(context, s, isDark, settings),
                              ),
                              const SizedBox(height: 12),
                            ],
                            if (audio.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(32),
                                child: Center(
                                  child: Text(
                                    'No audio streams found.',
                                    style: TextStyle(
                                      color: secClr,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _sectionHeader(
    BuildContext context,
    String title,
    IconData icon,
    Color color,
    bool isDark, {
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 8, bottom: 8, start: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
              fontSize: 10,
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }

  Widget _recommendBadge(bool isDark) {
    final amber = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: amber.withValues(alpha: 0.5), width: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star, size: 9, color: amber),
          const SizedBox(width: 3),
          Text(
            'RECOMMENDED',
            style: TextStyle(
              color: amber,
              fontSize: 8,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Future<bool> _showConfirmDialog({
    required BuildContext context,
    required String title,
    required String content,
  }) async {
    final result = await DmxConfirmDialog.show(
      context,
      title: title,
      message: content,
      confirmLabel: L10n.isRtl(context) ? 'متابعة' : 'Proceed',
      cancelLabel: L10n.isRtl(context) ? 'إلغاء' : 'Cancel',
      icon: Icons.warning_amber_rounded,
    );
    return result ?? false;
  }

  Widget _streamTile(
    BuildContext context,
    Map<String, dynamic> stream,
    bool isDark,
    SettingsProvider settings,
  ) {
    final type = stream['type'] as String? ?? 'muxed';
    final label = stream['label'] as String? ?? 'Stream';
    final size = stream['size'] as int? ?? 0;
    final ext = stream['ext'] as String? ?? '';
    final quality = stream['quality'] as String? ?? '';
    final color = _colorForType(type, isDark);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    String sizeLabel;
    if (size > 0) {
      if (type == 'combined' &&
          (stream['videoSize'] as int? ?? 0) > 0 &&
          (stream['audioSize'] as int? ?? 0) > 0) {
        sizeLabel =
            'V ${formatBytes(stream['videoSize'] as int)} + A ${formatBytes(stream['audioSize'] as int)} = ${formatBytes(size)}';
      } else {
        sizeLabel = formatBytes(size);
      }
    } else {
      sizeLabel = '—';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(13),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: () async {
            runHaptic(settings);
            final hasAudio = stream['audioSrc'] != null &&
                stream['audioSrc'].toString().isNotEmpty;
            if (type == 'video_only' && !hasAudio) {
              final confirm = await _showConfirmDialog(
                context: context,
                title: L10n.isRtl(context)
                    ? 'تنبيه فيديو بدون صوت'
                    : 'Silent Video Warning',
                content: L10n.isRtl(context)
                    ? 'هذا الملف يحتوي على الفيديو فقط وبدون صوت. هل تريد المتابعة؟'
                    : 'This file contains only video and has no audio. Do you want to proceed?',
              );
              if (!confirm || !context.mounted) return;
              Navigator.pop(context, stream);
            } else {
              Navigator.pop(context, stream);
            }
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: color.withValues(alpha: 0.22),
                width: 0.8,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(_iconForType(type), color: color, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: textClr,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        sizeLabel,
                        style: TextStyle(
                          color: mutedClr,
                          fontSize: 10,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
                if (quality.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: color.withValues(alpha: 0.35)),
                    ),
                    child: Text(
                      quality.toUpperCase(),
                      style: TextStyle(
                        color: color,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.6,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                Text(
                  '.$ext',
                  style: TextStyle(
                    color: secClr,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.download_rounded, color: color, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Backward-compatible alias so existing callers don't break.
typedef YoutubeQualitySheet = MediaQualitySheet;
