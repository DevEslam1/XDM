import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/services/google_auth_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../settings/provider/settings_provider.dart';

/// A bottom sheet that fetches available streams for a URL (any
/// yt-dlp-supported site) and lets the user pick one. Returns the selected
/// stream map via Navigator.pop.
class MediaQualitySheet extends StatefulWidget {
  final String videoUrl;
  /// Pre-fetched streams. When provided the sheet skips the backend fetch
  /// entirely, avoiding redundant calls that trigger 429 rate limits.
  final List<Map<String, dynamic>>? preloadedStreams;

  const MediaQualitySheet({
    super.key,
    required this.videoUrl,
    this.preloadedStreams,
  });

  static bool _isShowing = false;

  /// Shows the sheet and returns the chosen stream map, or null if dismissed.
  /// If only 1 stream format is available, returns it immediately without showing UI.
  /// Pass [preloadedStreams] to skip the backend fetch inside the sheet.
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

      // Only fetch if we don't already have streams from the caller.
      if (preloadedStreams == null) {
        try {
          final fetched = await YoutubeService.getStreamsForAnyUrl(videoUrl);
          if (fetched != null && fetched.length == 1) {
            return fetched.first;
          }
          preloadedStreams = fetched;
        } catch (_) {
          // Fall through — sheet will show its own error/retry state
        }
      } else if (preloadedStreams.length == 1) {
        return preloadedStreams.first;
      }

      if (!context.mounted) return null;

      return await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
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
    if (widget.preloadedStreams != null && widget.preloadedStreams!.isNotEmpty) {
      // Use caller-provided streams — no backend call needed.
      _streams = widget.preloadedStreams!;
      _isLoading = false;
    } else {
      _fetchStreams();
    }
  }

  Future<void> _fetchStreams() async {
    try {
      final streams = await YoutubeService.getStreamsForAnyUrl(widget.videoUrl);
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
    } catch (e) {
      if (!mounted) return;
      final errorStr = e.toString().replaceAll('Exception: ', '');
      setState(() {
        _isLoading = false;
        if (errorStr.toLowerCase().contains('rate limit')) {
          _errorMessage = L10n.isRtl(context)
              ? 'تم الوصول إلى حد الطلبات. يرجى المحاولة لاحقاً.'
              : errorStr;
        } else {
          _errorMessage = L10n.isRtl(context)
              ? 'فشل جلب البث: $errorStr'
              : 'Failed to fetch streams: $errorStr';
        }
      });
    }
  }


  /// Extracts numeric height from a quality label like "720p" or "1080p".
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
    final secClr = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    // Group streams by type
    final muxed = _streams
        .where((s) => s['type'] == 'muxed')
        .toList();
    final audio = _streams
        .where((s) => s['type'] == 'audio')
        .toList();
    final combined =
        _streams
            .where((s) => s['type'] == 'combined')
            .toList()
          ..sort((a, b) {
            final aQuality = _parseQuality(a['quality'] as String? ?? '');
            final bQuality = _parseQuality(b['quality'] as String? ?? '');
            return bQuality.compareTo(aQuality); // descending
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
                    color: isDark
                        ? AppTheme.glassBorder
                        : AppTheme.lightGlassBorder,
                    width: 0.8,
                  ),
                ),
              ),
              child: Column(
                children: [
                  // Handle bar
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

                  // Header
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(14),
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
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: accent,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.0,
                                      fontSize: 14,
                                    ),
                              ),
                              if (!_isLoading && _streams.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
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
                      ],
                    ),
                  ),

                  // Legal Warning Banner
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.amber.withValues(alpha: 0.3), width: 0.8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.gavel_rounded, size: 14, color: Colors.amber),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              L10n.of(context, 'yt_legal_warning'),
                              style: TextStyle(
                                color: secClr,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 6),

                  // Tabs
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _selectedTabIndex = 0),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: _selectedTabIndex == 0
                                    ? accent.withValues(alpha: 0.15)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _selectedTabIndex == 0
                                      ? accent
                                      : (isDark
                                            ? AppTheme.glassBorder
                                            : AppTheme.lightGlassBorder),
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                L10n.of(context, 'video_label'),
                                style: TextStyle(
                                  color: _selectedTabIndex == 0
                                      ? accent
                                      : secClr,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _selectedTabIndex = 1),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: _selectedTabIndex == 1
                                    ? (isDark
                                              ? AppTheme.neonGreen
                                              : AppTheme.lightNeonGreen)
                                          .withValues(alpha: 0.15)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _selectedTabIndex == 1
                                      ? (isDark
                                            ? AppTheme.neonGreen
                                            : AppTheme.lightNeonGreen)
                                      : (isDark
                                            ? AppTheme.glassBorder
                                            : AppTheme.lightGlassBorder),
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                L10n.of(context, 'audio_label'),
                                style: TextStyle(
                                  color: _selectedTabIndex == 1
                                      ? (isDark
                                            ? AppTheme.neonGreen
                                            : AppTheme.lightNeonGreen)
                                      : secClr,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Content
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

                              // Google Sign-In button when auth error
                              if (_errorMessage!.contains('age-restricted') ||
                                  _errorMessage!.contains('sign-in') ||
                                  _errorMessage!.contains('Sign in') ||
                                  _errorMessage!.contains('تسجيل الدخول')) ...[
                                ElevatedButton.icon(
                                  onPressed: () async {
                                    var success =
                                        await GoogleAuthService().signIn();
                                    if (!success) {
                                      await YoutubeService.authenticateFromBrowser();
                                      if (YoutubeService.isSignedIn) {
                                        success = true;
                                      }
                                    }
                                    if (success && mounted) {
                                      setState(() {
                                        _isLoading = true;
                                        _errorMessage = null;
                                        _streams = [];
                                      });
                                      _fetchStreams(); // Retry with auth
                                    }
                                  },
                                  icon: const Icon(Icons.login_rounded,
                                      size: 16),
                                  label: Text(
                                    L10n.isRtl(context)
                                        ? 'تسجيل الدخول بحساب Google'
                                        : 'SIGN IN WITH GOOGLE',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        accent.withValues(alpha: 0.1),
                                    foregroundColor: accent,
                                    side: BorderSide(color: accent),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],

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
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        children: [
                          if (_selectedTabIndex == 0) ...[
                            if (combined.isNotEmpty) ...[
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
                              ...combined.map(
                                (s) =>
                                    _streamTile(context, s, isDark, settings),
                              ),
                              const SizedBox(height: 12),
                            ],
                            if (combined.isEmpty && muxed.isNotEmpty) ...[
                              _sectionHeader(
                                context,
                                'VIDEO + AUDIO (MUXED)',
                                Icons.ondemand_video_outlined,
                                accent,
                                isDark,
                              ),
                              ...muxed.map(
                                (s) =>
                                    _streamTile(context, s, isDark, settings),
                              ),
                              const SizedBox(height: 12),
                            ],
                            if (combined.isEmpty && muxed.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(32),
                                child: Center(
                                  child: Text(
                                    'No MP4 video streams found.',
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
                                isDark
                                    ? AppTheme.neonGreen
                                    : AppTheme.lightNeonGreen,
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
      padding: const EdgeInsets.only(top: 8, bottom: 8, left: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber)
            .withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: (isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber)
              .withValues(alpha: 0.5),
          width: 0.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.star,
            size: 9,
            color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
          ),
          const SizedBox(width: 3),
          Text(
            'RECOMMENDED',
            style: TextStyle(
              color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
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
    required bool isDark,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
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
            title,
            style: TextStyle(
              color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          content: Text(
            content,
            style: TextStyle(
              color: isDark
                  ? AppTheme.textSecondary
                  : AppTheme.lightTextSecondary,
              fontSize: 13,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                L10n.isRtl(context) ? 'إلغاء' : 'Cancel',
                style: TextStyle(
                  color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue)
                        .withValues(alpha: 0.1),
                side: BorderSide(
                  color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                L10n.isRtl(context) ? 'متابعة' : 'Proceed',
                style: TextStyle(
                  color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        );
      },
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
    final color = _colorForType(type, isDark);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GlassCard(
        borderRadius: 14,
        padding: EdgeInsets.zero,
        isDarkMode: isDark,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 2,
            ),
            leading: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_iconForType(type), color: color, size: 18),
            ),
            title: Text(
              label,
              style: TextStyle(
                color: textClr,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Text(
              type == 'combined' && (stream['videoSize'] as int? ?? 0) > 0 && (stream['audioSize'] as int? ?? 0) > 0
                  ? 'Video: ${formatBytes(stream['videoSize'] as int)} + Audio: ${formatBytes(stream['audioSize'] as int)} = ${formatBytes(size)} • .$ext'
                  : '${formatBytes(size)} • .$ext',
              style: TextStyle(color: secClr, fontSize: 10),
            ),
            trailing: Icon(Icons.download_rounded, color: color, size: 20),
            onTap: () async {
              runHaptic(settings);
              if (type == 'video_only') {
                final confirm = await _showConfirmDialog(
                  context: context,
                  title: L10n.isRtl(context)
                      ? 'تنبيه فيديو بدون صوت'
                      : 'Silent Video Warning',
                  content: L10n.isRtl(context)
                      ? 'هذا الملف يحتوي على الفيديو فقط وبدون صوت. هل تريد المتابعة؟'
                      : 'This file contains only video and has no audio. Do you want to proceed?',
                  isDark: isDark,
                );
                if (!confirm || !context.mounted) return;
                Navigator.pop(context, stream);
              } else {
                Navigator.pop(context, stream);
              }
            },
          ),
        ),
      ),
    );
  }
}

/// Backward-compatible alias so existing callers don't break.
typedef YoutubeQualitySheet = MediaQualitySheet;
