import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../settings/provider/settings_provider.dart';

/// A bottom sheet that fetches available YouTube streams for a single video
/// and lets the user pick one. Returns the selected stream map via Navigator.pop.
class YoutubeQualitySheet extends StatefulWidget {
  final String videoUrl;
  const YoutubeQualitySheet({super.key, required this.videoUrl});

  /// Shows the sheet and returns the chosen stream map, or null if dismissed.
  static Future<Map<String, dynamic>?> show(BuildContext context, String videoUrl) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    runHaptic(settings);
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => YoutubeQualitySheet(videoUrl: videoUrl),
    );
  }

  @override
  State<YoutubeQualitySheet> createState() => _YoutubeQualitySheetState();
}

class _YoutubeQualitySheetState extends State<YoutubeQualitySheet> {
  List<Map<String, dynamic>> _streams = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchStreams();
  }

  Future<void> _fetchStreams() async {
    try {
      final streams = await YoutubeService.getStreams(widget.videoUrl);
      if (!mounted) return;
      setState(() {
        _streams = streams;
        _isLoading = false;
        if (streams.isEmpty) {
          _errorMessage = 'No streams found for this video.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to fetch streams: $e';
      });
    }
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'muxed':
        return Icons.ondemand_video_outlined;
      case 'audio':
        return Icons.audiotrack_outlined;
      case 'video_only':
        return Icons.videocam_outlined;
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
      default:
        return isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    // Group streams by type
    final muxed = _streams.where((s) => s['type'] == 'muxed').toList();
    final audio = _streams.where((s) => s['type'] == 'audio').toList();
    final videoOnly = _streams.where((s) => s['type'] == 'video_only').toList();

    final videoTitle = _streams.isNotEmpty ? (_streams.first['title'] as String? ?? 'YouTube Video') : 'YouTube Video';

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
                color: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.95),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border(
                  top: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, width: 0.8),
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
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.play_circle_filled, color: Colors.red, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'YOUTUBE VIDEO QUALITY',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
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
                                    style: TextStyle(color: secClr, fontSize: 11),
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

                  const SizedBox(height: 8),

                  // Content
                  if (_isLoading)
                    const Expanded(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
                            SizedBox(height: 16),
                            Text('Fetching available streams...', style: TextStyle(fontSize: 12)),
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
                              Icon(Icons.error_outline, color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed, size: 40),
                              const SizedBox(height: 12),
                              Text(
                                _errorMessage!,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: secClr, fontSize: 12),
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
                          if (muxed.isNotEmpty) ...[
                            _sectionHeader(context, 'VIDEO + AUDIO (MUXED)', Icons.ondemand_video_outlined, accent, isDark),
                            ...muxed.map((s) => _streamTile(context, s, isDark, settings)),
                            const SizedBox(height: 12),
                          ],
                          if (audio.isNotEmpty) ...[
                            _sectionHeader(context, 'AUDIO ONLY', Icons.audiotrack_outlined,
                                isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen, isDark),
                            ...audio.map((s) => _streamTile(context, s, isDark, settings)),
                            const SizedBox(height: 12),
                          ],
                          if (videoOnly.isNotEmpty) ...[
                            _sectionHeader(context, 'VIDEO ONLY (NO AUDIO)', Icons.videocam_outlined,
                                isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet, isDark),
                            ...videoOnly.map((s) => _streamTile(context, s, isDark, settings)),
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

  Widget _sectionHeader(BuildContext context, String title, IconData icon, Color color, bool isDark) {
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
        ],
      ),
    );
  }

  Widget _streamTile(BuildContext context, Map<String, dynamic> stream, bool isDark, SettingsProvider settings) {
    final type = stream['type'] as String? ?? 'muxed';
    final label = stream['label'] as String? ?? 'Stream';
    final size = stream['size'] as int? ?? 0;
    final ext = stream['ext'] as String? ?? '';
    final color = _colorForType(type, isDark);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

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
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
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
              style: TextStyle(color: textClr, fontSize: 12, fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              '${formatBytes(size)} • .$ext',
              style: TextStyle(color: secClr, fontSize: 10),
            ),
            trailing: Icon(Icons.download_rounded, color: color, size: 20),
            onTap: () {
              runHaptic(settings);
              Navigator.pop(context, stream);
            },
          ),
        ),
      ),
    );
  }
}
