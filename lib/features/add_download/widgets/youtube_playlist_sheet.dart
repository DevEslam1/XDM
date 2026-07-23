import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../../../shared/widgets/themed_snackbar.dart';

/// Result returned when the user confirms playlist download.
class PlaylistDownloadResult {
  final List<Map<String, dynamic>> selectedVideos;
  final String qualityPreset;
  final String playlistTitle;

  const PlaylistDownloadResult({
    required this.selectedVideos,
    required this.qualityPreset,
    required this.playlistTitle,
  });
}

/// A draggable bottom sheet that shows all videos in a YouTube playlist,
/// lets the user select/deselect videos, pick a quality preset, and
/// batch-enqueue them for download.
class YoutubePlaylistSheet extends StatefulWidget {
  final String playlistUrl;
  const YoutubePlaylistSheet({super.key, required this.playlistUrl});

  /// Shows the sheet and returns the result, or null if dismissed.
  static Future<PlaylistDownloadResult?> show(
    BuildContext context,
    String playlistUrl,
  ) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    runHaptic(settings);
    return showModalBottomSheet<PlaylistDownloadResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => YoutubePlaylistSheet(playlistUrl: playlistUrl),
    );
  }

  @override
  State<YoutubePlaylistSheet> createState() => _YoutubePlaylistSheetState();
}

class _YoutubePlaylistSheetState extends State<YoutubePlaylistSheet> {
  Map<String, dynamic>? _playlistInfo;
  List<Map<String, dynamic>> _videos = [];
  bool _isLoading = true;
  bool _isDownloading = false;
  bool _isCancelled = false;
  String? _errorMessage;
  String _qualityPreset = 'best_combined';
  int _downloadProgress = 0;
  String _currentVideoTitle = '';
  String _searchQuery = '';

  List<Map<String, dynamic>> get _filteredVideos {
    if (_searchQuery.isEmpty) return _videos;
    final query = _searchQuery.toLowerCase();
    return _videos.where((v) {
      final title = (v['title'] as String? ?? '').toLowerCase();
      return title.contains(query);
    }).toList();
  }

  static const List<Map<String, String>> _qualityOptions = [
    {'value': 'best_combined', 'label': 'Best Quality (Auto Merge)'},
    {'value': 'best_muxed', 'label': 'Best Compatible (.mp4)'},
    {'value': 'audio_only', 'label': 'Audio Only'},
  ];

  @override
  void initState() {
    super.initState();
    _fetchPlaylist();
  }

  Future<void> _fetchPlaylist() async {
    try {
      final details = await YoutubeService.getPlaylistDetails(
        widget.playlistUrl,
      );

      if (!mounted) return;
      final info = details?['info'] as Map<String, dynamic>?;
      final videos = List<Map<String, dynamic>>.from((details?['videos'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)) ?? []);

      setState(() {
        _playlistInfo = info;
        _videos = videos;
        _isLoading = false;
        if (videos.isEmpty && info != null) {
          final count = info['videoCount'] as int? ?? 0;
          if (count > 0) {
            _errorMessage =
                'Could not load video list for this playlist ($count videos). '
                'Try again or use the browser to add videos individually.';
          } else {
            _errorMessage = 'No videos found in this playlist.';
          }
        } else if (videos.isEmpty) {
          _errorMessage = 'No videos found in this playlist.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to load playlist. Check the URL and try again.';
      });
    }
  }

  int get _selectedCount => _filteredVideos.where((v) => v['selected'] == true).length;

  void _toggleAll(bool selected) {
    setState(() {
      for (int i = 0; i < _filteredVideos.length; i++) {
        final idx = _videos.indexOf(_filteredVideos[i]);
        if (idx != -1) {
          _videos[idx] = {..._videos[idx], 'selected': selected};
        }
      }
    });
  }

  Future<void> _startBatchDownload() async {
    final selectedVideos = _videos.where((v) => v['selected'] == true).toList();
    if (selectedVideos.isEmpty) return;

    setState(() {
      _isDownloading = true;
      _isCancelled = false;
    });

    final provider = Provider.of<DownloadProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final savePath = settings.customDownloadPath ?? '';
    final isDark = settings.isDarkMode;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;

    int completed = 0;
    int failed = 0;
    int consecutiveErrors = 0;
    final enqueuedVideos = <Map<String, dynamic>>[];

    for (int i = 0; i < selectedVideos.length; i++) {
      if (!mounted) break;
      if (_isCancelled) break;

      final video = selectedVideos[i];
      final videoId = video['id'] as String;
      final videoTitle = video['title'] as String? ?? 'YouTube Video';

      try {
        final videoUrl = YoutubeService.videoUrl(videoId);
        final ext = _qualityPreset == 'audio_only' ? 'm4a' : 'mp4';

        String displayQuality = _qualityPreset;
        if (_qualityPreset == 'best_combined') displayQuality = 'Best';
        if (_qualityPreset == 'audio_only') displayQuality = 'Audio';

        final fileName = '$videoTitle [$displayQuality].$ext';

        await provider.addDownload(
          name: fileName,
          url: videoUrl,
          size: 0,
          category: _qualityPreset == 'audio_only' ? 'Audio' : 'Video',
          savePath: savePath,
          downloadPageUrl: videoUrl,
          youtubeQualityPreset: _qualityPreset,
        );
        enqueuedVideos.add(video);
        completed++;
        consecutiveErrors = 0;
      } catch (e) {
        debugPrint('Failed to enqueue video $videoId: $e');
        failed++;
        consecutiveErrors++;
      }

      // If too many consecutive failures, abort early (likely rate-limited)
      if (consecutiveErrors >= 5) {
        debugPrint(
          'Too many consecutive failures. Aborting playlist download.',
        );
        if (mounted) {
          ThemedSnackbar.show(
            context,
            message: 'Too many failures. Aborting after ${completed + 1} videos.',
            color: redClr,
            icon: Icons.error_outline,
            isDarkMode: settings.isDarkMode,
          );
        }
        break;
      }

      if (mounted) {
        setState(() {
          _downloadProgress = completed;
          _currentVideoTitle = videoTitle;
        });
      }
    }

    if (mounted) {
      if (failed > 0) {
        final remaining = selectedVideos.length - completed;
        final msg = remaining > 0
            ? '$failed video(s) failed ($remaining skipped).'
            : '$failed video(s) failed (stream not available).';
        ThemedSnackbar.show(
          context,
          message: msg,
          color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
          icon: Icons.warning_amber_rounded,
          isDarkMode: settings.isDarkMode,
        );
      }
      Navigator.pop(
        context,
        enqueuedVideos.isEmpty
            ? null
            : PlaylistDownloadResult(
                selectedVideos: enqueuedVideos,
                qualityPreset: _qualityPreset,
                playlistTitle: _playlistInfo?['title'] as String? ?? 'Playlist',
              ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final glassBorder = isDark
        ? AppTheme.glassBorder
        : AppTheme.lightGlassBorder;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
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
                border: Border(top: BorderSide(color: glassBorder, width: 0.8)),
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
                            color: Colors.red.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(
                            Icons.playlist_play_rounded,
                            color: Colors.red,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'YOUTUBE PLAYLIST',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: accent,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.0,
                                      fontSize: 14,
                                    ),
                              ),
                              if (_playlistInfo != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    _playlistInfo!['title'] as String? ?? '',
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

                  // Loading / Error / Content
                  if (_isLoading)
                    const Expanded(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                              ),
                            ),
                            SizedBox(height: 16),
                            Text(
                              'Loading playlist...',
                              style: TextStyle(fontSize: 12),
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
                                color: redClr,
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
                                    _videos = [];
                                    _playlistInfo = null;
                                  });
                                  _fetchPlaylist();
                                },
                                icon: Icon(
                                  Icons.refresh_rounded,
                                  size: 16,
                                  color: accent,
                                ),
                                label: Text(
                                  'RETRY',
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
                  else ...[
                    // Playlist info bar
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          if (_playlistInfo?['author'] != null) ...[
                            Icon(
                              Icons.person_outline,
                              size: 13,
                              color: mutedClr,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _playlistInfo!['author'] as String,
                              style: TextStyle(color: mutedClr, fontSize: 10),
                            ),
                            const SizedBox(width: 12),
                          ],
                          Icon(
                            Icons.video_library_outlined,
                            size: 13,
                            color: mutedClr,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${_filteredVideos.length}${_searchQuery.isNotEmpty ? ' / ${_videos.length}' : ''} videos',
                            style: TextStyle(color: mutedClr, fontSize: 10),
                          ),
                          const Spacer(),
                          // Select all / deselect all
                          TextButton.icon(
                            onPressed: () {
                              runHaptic(settings);
                              _toggleAll(_selectedCount < _filteredVideos.length);
                            },
                            icon: Icon(
                              _selectedCount == _filteredVideos.length && _filteredVideos.isNotEmpty
                                  ? Icons.deselect
                                  : Icons.select_all,
                              size: 14,
                              color: accent,
                            ),
                            label: Text(
                              _selectedCount == _filteredVideos.length && _filteredVideos.isNotEmpty
                                  ? 'DESELECT ALL'
                                  : 'SELECT ALL',
                              style: TextStyle(
                                color: accent,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Search field
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: TextField(
                        onChanged: (val) => setState(() => _searchQuery = val),
                        decoration: InputDecoration(
                          hintText: 'Search videos...',
                          hintStyle: TextStyle(color: mutedClr, fontSize: 13),
                          prefixIcon: Icon(Icons.search, size: 16, color: mutedClr),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: Icon(Icons.clear, size: 16, color: mutedClr),
                                  onPressed: () => setState(() => _searchQuery = ''),
                                )
                              : null,
                          filled: true,
                          fillColor: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.6),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: glassBorder),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: glassBorder),
                          ),
                        ),
                        style: TextStyle(color: textClr, fontSize: 13),
                      ),
                    ),

                    const Divider(height: 1, thickness: 0.5),

                    // Video list
                    Expanded(
                      child: ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        itemCount: _filteredVideos.length,
                        itemBuilder: (context, index) {
                          final video = _filteredVideos[index];
                          final isSelected = video['selected'] as bool? ?? true;
                          final title =
                              video['title'] as String? ?? 'Video ${index + 1}';
                          final duration = video['duration'] as int? ?? 0;
                          final author = video['author'] as String? ?? '';
                          final thumbnailUrl = video['thumbnailUrl'] as String?;

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
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () {
                                    runHaptic(settings);
                                    final originalIndex = _videos.indexOf(video);
                                    if (originalIndex != -1) {
                                      setState(() {
                                        _videos[originalIndex] = {
                                          ...video,
                                          'selected': !isSelected,
                                        };
                                      });
                                    }
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      children: [
                                        // Checkbox
                                        SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: Checkbox(
                                            value: isSelected,
                                            activeColor: accent,
                                            side: BorderSide(
                                              color: glassBorder,
                                              width: 0.8,
                                            ),
                                            onChanged: (val) {
                                              if (val != null) {
                                                final originalIndex = _videos.indexOf(video);
                                                if (originalIndex != -1) {
                                                  setState(() {
                                                    _videos[originalIndex] = {
                                                      ...video,
                                                      'selected': val,
                                                    };
                                                  });
                                                }
                                              }
                                            },
                                          ),
                                        ),
                                        const SizedBox(width: 10),

                                        // Thumbnail
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: SizedBox(
                                            width: 72,
                                            height: 42,
                                            child: thumbnailUrl != null
                                                ? Image.network(
                                                    thumbnailUrl,
                                                    fit: BoxFit.cover,
                                                    errorBuilder: (context, error, stackTrace) => Container(
                                                      color:
                                                          (isDark
                                                                  ? AppTheme
                                                                        .background
                                                                  : AppTheme
                                                                        .lightBackground)
                                                              .withValues(
                                                                alpha: 0.6,
                                                              ),
                                                      child: Icon(
                                                        Icons
                                                            .play_circle_outline,
                                                        color: mutedClr,
                                                        size: 24,
                                                      ),
                                                    ),
                                                  )
                                                : Container(
                                                    color:
                                                        (isDark
                                                                ? AppTheme
                                                                      .background
                                                                : AppTheme
                                                                      .lightBackground)
                                                            .withValues(
                                                              alpha: 0.6,
                                                            ),
                                                    child: Icon(
                                                      Icons.play_circle_outline,
                                                      color: mutedClr,
                                                      size: 24,
                                                    ),
                                                  ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),

                                        // Title & info
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                title,
                                                style: TextStyle(
                                                  color: isSelected
                                                      ? textClr
                                                      : secClr,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                  decoration: isSelected
                                                      ? null
                                                      : TextDecoration
                                                            .lineThrough,
                                                ),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 3),
                                              Row(
                                                children: [
                                                  if (author.isNotEmpty) ...[
                                                    Flexible(
                                                      child: Text(
                                                        author,
                                                        style: TextStyle(
                                                          color: mutedClr,
                                                          fontSize: 9,
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                  ],
                                                  Icon(
                                                    Icons.access_time,
                                                    size: 10,
                                                    color: mutedClr,
                                                  ),
                                                  const SizedBox(width: 3),
                                                  Text(
                                                    YoutubeService.formatDuration(
                                                      duration,
                                                    ),
                                                    style: TextStyle(
                                                      color: mutedClr,
                                                      fontSize: 9,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),

                                        // Index number
                                        Text(
                                          '#${index + 1}',
                                          style: TextStyle(
                                            color: mutedClr,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),

                    // Bottom action bar
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      decoration: BoxDecoration(
                        color:
                            (isDark ? AppTheme.surface : AppTheme.lightSurface)
                                .withValues(alpha: 0.9),
                        border: Border(
                          top: BorderSide(color: glassBorder, width: 0.6),
                        ),
                      ),
                      child: SafeArea(
                        top: false,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Quality selector
                            Row(
                              children: [
                                Text(
                                  'QUALITY',
                                  style: TextStyle(
                                    color: secClr,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          (isDark
                                                  ? AppTheme.background
                                                  : AppTheme.lightBackground)
                                              .withValues(alpha: 0.6),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: glassBorder,
                                        width: 0.8,
                                      ),
                                    ),
                                    child: DropdownButtonHideUnderline(
                                      child: DropdownButton<String>(
                                        dropdownColor: isDark
                                            ? AppTheme.surface
                                            : AppTheme.lightSurface,
                                        value: _qualityPreset,
                                        isExpanded: true,
                                        icon: Icon(
                                          Icons.arrow_drop_down,
                                          color: secClr,
                                        ),
                                        style: TextStyle(
                                          color: textClr,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        items: _qualityOptions.map((opt) {
                                          return DropdownMenuItem<String>(
                                            value: opt['value'],
                                            child: Text(opt['label']!),
                                          );
                                        }).toList(),
                                        onChanged: _isDownloading
                                            ? null
                                            : (val) {
                                                if (val != null) {
                                                  setState(
                                                    () => _qualityPreset = val,
                                                  );
                                                }
                                              },
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (_qualityPreset == 'best_muxed' ||
                                _qualityPreset == 'best_combined')
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 8,
                                  left: 60,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.info_outline,
                                      size: 12,
                                      color: isDark
                                          ? AppTheme.neonAmber
                                          : AppTheme.lightNeonAmber,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        _qualityPreset == 'best_combined'
                                            ? (L10n.isRtl(context)
                                                  ? 'ملاحظة: سيتم دمج أفضل جودة صوت وصورة تلقائياً.'
                                                  : 'Note: Best video and audio will be auto-merged.')
                                            : (L10n.isRtl(context)
                                                  ? 'ملاحظة: سيتم تحميل أفضل جودة مدمجة (غالباً 360p).'
                                                  : 'Note: Best merged quality will be downloaded (usually 360p).'),
                                        style: TextStyle(
                                          color: isDark
                                              ? AppTheme.neonAmber
                                              : AppTheme.lightNeonAmber,
                                          fontSize: 10,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 12),

                            // Download progress or button
                            if (_isDownloading)
                              Column(
                                children: [
                                  LinearProgressIndicator(
                                    value: _selectedCount > 0
                                        ? _downloadProgress / _selectedCount
                                        : 0,
                                    backgroundColor: glassBorder,
                                    color: greenClr,
                                    minHeight: 4,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              L10n.isRtl(context)
                                                  ? 'جاري إضافة $_downloadProgress من $_selectedCount فيديو...'
                                                  : 'Enqueuing $_downloadProgress of $_selectedCount videos...',
                                              style: TextStyle(
                                                color: secClr,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            if (_currentVideoTitle.isNotEmpty)
                                              Padding(
                                                padding: const EdgeInsets.only(top: 2),
                                                child: Text(
                                                  _currentVideoTitle,
                                                  style: TextStyle(
                                                    color: mutedClr,
                                                    fontSize: 10,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: () {
                                          runHaptic(settings);
                                          setState(() => _isCancelled = true);
                                        },
                                        style: TextButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 4,
                                          ),
                                          minimumSize: Size.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        child: Text(
                                          L10n.isRtl(context)
                                              ? 'إلغاء'
                                              : 'CANCEL',
                                          style: TextStyle(
                                            color: redClr,
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              )
                            else
                              NeonGlowButton(
                                isExpanded: true,
                                isFilled: true,
                                onPressed: _selectedCount == 0
                                    ? null
                                    : _startBatchDownload,
                                text: L10n.isRtl(context)
                                    ? 'تحميل $_selectedCount فيديو'
                                    : 'DOWNLOAD $_selectedCount VIDEO${_selectedCount != 1 ? 'S' : ''}',
                                icon: Icons.download_rounded,
                                color: accent,
                                glowColor: accent,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
