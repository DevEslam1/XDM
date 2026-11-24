import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';
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
  static bool _hasSeenSilentVideoWarning = false;

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
      return await showDmxModalBottomSheet<Map<String, dynamic>>(
        context: context,
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
  List<Map<String, dynamic>> _memoizedVideos = [];
  List<Map<String, dynamic>> _memoizedAudios = [];
  bool _isLoading = true;
  String? _errorMessage;
  int _selectedTabIndex = 0;
  int _displayedVideoCount = 20;
  int _displayedAudioCount = 20;

  @override
  void initState() {
    super.initState();
    if (widget.preloadedStreams != null &&
        widget.preloadedStreams!.isNotEmpty) {
      _streams = widget.preloadedStreams!;
      _isLoading = false;
      _processAndMemoizeStreams();
    } else {
      _fetchStreams();
    }
  }

  @override
  void didUpdateWidget(covariant MediaQualitySheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl ||
        oldWidget.preloadedStreams != widget.preloadedStreams) {
      if (widget.preloadedStreams != null &&
          widget.preloadedStreams!.isNotEmpty) {
        _streams = widget.preloadedStreams!;
        _isLoading = false;
        _processAndMemoizeStreams();
      } else {
        _fetchStreams();
      }
    }
  }

  int _parseQuality(String q) {
    final match = RegExp(r'(\d+)').firstMatch(q);
    return match != null ? int.parse(match.group(1)!) : 0;
  }

  void _processAndMemoizeStreams() {
    final audio = _streams.where((s) => s['type'] == 'audio').toList()
      ..sort((a, b) {
        final aSize = (a['size'] as num? ?? 0).toInt();
        final bSize = (b['size'] as num? ?? 0).toInt();
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
          // Keep mp4
        } else {
          final existingSize = (existing['videoSize'] as num? ?? 0).toInt() > 0
              ? (existing['videoSize'] as num).toInt()
              : (existing['size'] as num? ?? 0).toInt();
          final currentSize = (s['videoSize'] as num? ?? 0).toInt() > 0
              ? (s['videoSize'] as num).toInt()
              : (s['size'] as num? ?? 0).toInt();
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
        final aSize = (pairedAudio['size'] as num? ?? 0).toInt() > 0
            ? (pairedAudio['size'] as num).toInt()
            : (pairedAudio['audioSize'] as num? ?? 0).toInt();
        final vSize = (v['videoSize'] as num? ?? 0).toInt() > 0
            ? (v['videoSize'] as num).toInt()
            : (v['size'] as num? ?? 0).toInt();
        v['audioSrc'] = audioUrl?.toString();
        v['videoSize'] = vSize;
        v['audioSize'] = aSize;
        v['size'] = vSize + aSize;
        v['type'] = 'combined';
        final qLabel = v['quality']?.toString() ?? '';
        v['label'] = (v['label'] as String?)?.isNotEmpty == true
            ? v['label']
            : (qLabel.isNotEmpty ? '$qLabel MP4' : 'Video MP4');
      }
      return v;
    }).toList()
      ..sort((a, b) {
        final aHeight = _parseQuality(a['quality'] as String? ?? '');
        final bHeight = _parseQuality(b['quality'] as String? ?? '');
        return bHeight.compareTo(aHeight);
      });

    _memoizedVideos = videoList;
    _memoizedAudios = audio;
  }

  Future<void> _fetchStreams() async {
    debugPrint('[MediaQualitySheet] Fetching streams for: ${widget.videoUrl}');
    try {
      await YoutubeService.fetchCookiesFromWebView();
      if (!mounted) return;
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
        } else {
          _processAndMemoizeStreams();
        }
      });
    } catch (e, st) {
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

  void _refreshStreams() {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _streams = [];
      _memoizedVideos = [];
      _memoizedAudios = [];
    });
    _fetchStreams();
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

  void _onScrollNotification(ScrollNotification notification) {
    if (notification.metrics.pixels >=
        notification.metrics.maxScrollExtent - 150) {
      if (_selectedTabIndex == 0 &&
          _displayedVideoCount < _memoizedVideos.length) {
        setState(() {
          _displayedVideoCount =
              (_displayedVideoCount + 20).clamp(0, _memoizedVideos.length);
        });
      } else if (_selectedTabIndex == 1 &&
          _displayedAudioCount < _memoizedAudios.length) {
        setState(() {
          _displayedAudioCount =
              (_displayedAudioCount + 20).clamp(0, _memoizedAudios.length);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isAmoled = settings.isAmoledMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final green = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final amber = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    final red = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final secClr = AppTheme.textSecondaryOf(isDark);
    final hairline = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);
    final panelBg = AppTheme.panelBg(isDark, isAmoled: isAmoled);

    final videoList = _memoizedVideos;
    final audio = _memoizedAudios;
    final videoTitle = _streams.isNotEmpty
        ? (_streams.first['title'] as String? ?? 'Media')
        : null;

    return DmxSheetContainer(
      scrollable: false,
      maxHeightFraction: 0.88,
      isDark: isDark,
      isAmoled: isAmoled,
      accentColor: accent,
      padding: EdgeInsets.zero,
      header: DmxSheetHeader(
        title: L10n.of(context, 'yt_video_quality'),
        subtitle: (!_isLoading && videoTitle != null) ? videoTitle : null,
        icon: Icons.play_circle_filled_rounded,
        accentColor: accent,
        isDark: isDark,
        trailing: IconButton(
          icon: _isLoading
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: accent,
                  ),
                )
              : Icon(
                  Icons.refresh_rounded,
                  color: accent,
                  size: 20,
                ),
          tooltip: L10n.of(context, 'retry_btn'),
          onPressed: _isLoading ? null : _refreshStreams,
        ),
      ),
      child: Column(
        children: [
          // Legal notice
          Padding(
            padding: const EdgeInsets.fromLTRB(
              DmxTokens.sheetHorizontalPadding,
              12,
              DmxTokens.sheetHorizontalPadding,
              8,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: amber.withValues(alpha: isDark ? 0.10 : 0.08),
                borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
                border: Border.all(
                  color: amber.withValues(alpha: 0.28),
                  width: 0.8,
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.gavel_rounded, size: 14, color: amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      L10n.of(context, 'yt_legal_warning'),
                      style: TextStyle(
                        fontFamily: AppTheme.fontBody,
                        color: secClr,
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Video / Audio segmented control
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: DmxTokens.sheetHorizontalPadding,
              vertical: 4,
            ),
            child: Container(
              height: 44,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: panelBg,
                borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                border: Border.all(color: hairline, width: 0.8),
              ),
              child: Row(
                children: [
                  _buildTabChip(
                    index: 0,
                    icon: Icons.videocam_rounded,
                    label: L10n.of(context, 'video_label'),
                    count: videoList.length,
                    color: accent,
                    isDark: isDark,
                  ),
                  _buildTabChip(
                    index: 1,
                    icon: Icons.audiotrack_rounded,
                    label: L10n.of(context, 'audio_label'),
                    count: audio.length,
                    color: green,
                    isDark: isDark,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Body
          if (_isLoading)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: accent,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      L10n.of(context, 'fetching_streams'),
                      style: TextStyle(
                        fontFamily: AppTheme.fontBody,
                        fontSize: 12.5,
                        color: secClr,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (_errorMessage != null)
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: red.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.error_outline_rounded,
                          color: red,
                          size: 28,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: AppTheme.fontBody,
                          color: secClr,
                          fontSize: 12.5,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: _refreshStreams,
                        icon: const Icon(Icons.refresh_rounded, size: 17),
                        label: Text(
                          L10n.of(context, 'retry_btn'),
                          style: const TextStyle(
                            fontFamily: AppTheme.fontDisplay,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: AppTheme.inkOn(accent),
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(DmxTokens.radiusMd),
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
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  _onScrollNotification(notification);
                  return false;
                },
                child: AnimatedSwitcher(
                  duration: AppTheme.motionFast,
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  child: ListView(
                    key: ValueKey<int>(_selectedTabIndex),
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(
                      DmxTokens.sheetHorizontalPadding,
                      4,
                      DmxTokens.sheetHorizontalPadding,
                      20,
                    ),
                    children: [
                      if (_selectedTabIndex == 0) ...[
                        if (videoList.isNotEmpty) ...[
                          _sectionHeader(
                            context,
                            L10n.of(context, 'video_label'),
                            Icons.video_file_outlined,
                            accent,
                            isDark,
                            trailing: _recommendBadge(isDark),
                          ),
                          ...videoList.take(_displayedVideoCount).map(
                                (s) => _streamTile(
                                  context,
                                  s,
                                  isDark,
                                  isAmoled,
                                  settings,
                                ),
                              ),
                          const SizedBox(height: 8),
                        ] else
                          _emptyNotice('No video streams found.', secClr),
                      ] else ...[
                        if (audio.isNotEmpty) ...[
                          _sectionHeader(
                            context,
                            L10n.of(context, 'audio_label'),
                            Icons.audiotrack_outlined,
                            green,
                            isDark,
                          ),
                          ...audio.take(_displayedAudioCount).map(
                                (s) => _streamTile(
                                  context,
                                  s,
                                  isDark,
                                  isAmoled,
                                  settings,
                                ),
                              ),
                          const SizedBox(height: 8),
                        ] else
                          _emptyNotice('No audio streams found.', secClr),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTabChip({
    required int index,
    required IconData icon,
    required String label,
    required int count,
    required Color color,
    required bool isDark,
  }) {
    final isSelected = _selectedTabIndex == index;
    final secClr = AppTheme.textSecondaryOf(isDark);

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _selectedTabIndex = index),
        child: AnimatedContainer(
          duration: AppTheme.motionFast,
          curve: AppTheme.motionCurve,
          decoration: BoxDecoration(
            color: isSelected
                ? color.withValues(alpha: isDark ? 0.16 : 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: isSelected
                ? Border.all(color: color.withValues(alpha: 0.35), width: 0.8)
                : null,
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: isSelected ? color : secClr),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      color: isSelected ? color : secClr,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                if (!_isLoading && count > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: (isSelected ? color : secClr)
                          .withValues(alpha: isSelected ? 0.2 : 0.12),
                      borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
                    ),
                    child: Text(
                      '$count',
                      style: AppTheme.dataStyle(
                        isDark: isDark,
                        size: 11,
                        color: isSelected ? color : secClr,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyNotice(String message, Color secClr) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
      child: Center(
        child: Text(
          message,
          style: TextStyle(
            fontFamily: AppTheme.fontBody,
            color: secClr,
            fontSize: 13,
          ),
        ),
      ),
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
      padding: const EdgeInsetsDirectional.only(top: 6, bottom: 10, start: 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            title,
            style: AppTheme.microLabel(isDark: isDark, color: color),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }

  Widget _recommendBadge(bool isDark) {
    final amber = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: isDark ? 0.18 : 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: amber.withValues(alpha: 0.4), width: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 10, color: amber),
          const SizedBox(width: 3),
          Text(
            'RECOMMENDED',
            style: TextStyle(
              fontFamily: AppTheme.fontDisplay,
              color: amber,
              fontSize: 9,
              fontWeight: FontWeight.w700,
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
    bool isAmoled,
    SettingsProvider settings,
  ) {
    final type = stream['type'] as String? ?? 'muxed';
    final label = stream['label'] as String? ?? 'Stream';
    final size = (stream['size'] as num? ?? 0).toInt();
    final ext = stream['ext'] as String? ?? '';
    final quality = stream['quality'] as String? ?? '';
    final color = _colorForType(type, isDark);
    final textClr = AppTheme.textPrimaryOf(isDark);
    final secClr = AppTheme.textSecondaryOf(isDark);
    final mutedClr = AppTheme.textMutedOf(isDark);
    final surfaceClr =
        AppTheme.surfaceColor(isDark, isAmoled: isAmoled, elevated: false);

    String sizeLabel;
    if (size > 0) {
      if (type == 'combined' &&
          (stream['videoSize'] as num? ?? 0).toInt() > 0 &&
          (stream['audioSize'] as num? ?? 0).toInt() > 0) {
        sizeLabel =
            'V ${formatBytes((stream['videoSize'] as num).toDouble())} + A ${formatBytes((stream['audioSize'] as num).toDouble())} = ${formatBytes(size.toDouble())}';
      } else {
        sizeLabel = formatBytes(size.toDouble());
      }
    } else {
      sizeLabel = '—';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: surfaceClr,
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
          onTap: () async {
            runHaptic(settings);
            final hasAudio = stream['audioSrc'] != null &&
                stream['audioSrc'].toString().isNotEmpty;
            if (type == 'video_only' && !hasAudio) {
              if (!MediaQualitySheet._hasSeenSilentVideoWarning) {
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
                MediaQualitySheet._hasSeenSilentVideoWarning = true;
              }
              if (context.mounted) {
                Navigator.pop(context, stream);
              }
            } else {
              Navigator.pop(context, stream);
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
              border: Border.all(
                color: color.withValues(alpha: isDark ? 0.24 : 0.20),
                width: 0.8,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: isDark ? 0.14 : 0.10),
                    borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
                  ),
                  child: Icon(_iconForType(type), color: color, size: 19),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          color: textClr,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        sizeLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.dataStyle(
                          isDark: isDark,
                          size: 11,
                          color: mutedClr,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (quality.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: isDark ? 0.14 : 0.10),
                      borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
                      border: Border.all(
                        color: color.withValues(alpha: 0.32),
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      quality.toUpperCase(),
                      style: AppTheme.dataStyle(
                        isDark: isDark,
                        size: 11,
                        color: color,
                      ),
                    ),
                  ),
                if (ext.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    '.$ext',
                    style: AppTheme.dataStyle(
                      isDark: isDark,
                      size: 11,
                      color: secClr,
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                Icon(Icons.download_rounded, color: color, size: 19),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

typedef YoutubeQualitySheet = MediaQualitySheet;
