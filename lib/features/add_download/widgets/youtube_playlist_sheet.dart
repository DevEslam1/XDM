import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';

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

class YoutubePlaylistSheet extends StatefulWidget {
  final String playlistUrl;
  const YoutubePlaylistSheet({super.key, required this.playlistUrl});
  static bool _isShowing = false;
  static Future<PlaylistDownloadResult?> show(
    BuildContext context,
    String playlistUrl,
  ) async {
    if (_isShowing) return null;
    _isShowing = true;
    try {
      final settings = Provider.of<SettingsProvider>(context, listen: false);
      runHaptic(settings);
      return await showModalBottomSheet<PlaylistDownloadResult>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.1),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        builder: (_) => YoutubePlaylistSheet(playlistUrl: playlistUrl),
      );
    } finally {
      _isShowing = false;
    }
  }

  @override
  State<YoutubePlaylistSheet> createState() => _YoutubePlaylistSheetState();
}

class _YoutubePlaylistSheetState extends State<YoutubePlaylistSheet> {
  Map<String, dynamic>? _playlistInfo;
  List<Map<String, dynamic>> _videos = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMoreVideos = true;
  dynamic _nextPageToken;
  String? _errorMessage;
  String? _note;
  String _qualityPreset = 'best_combined';
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
    {'value': 'best_combined', 'label': 'Best Quality (Auto)'},
    {'value': '2160p', 'label': '2160p (4K Ultra HD)'},
    {'value': '1440p', 'label': '1440p (2K Quad HD)'},
    {'value': '1080p', 'label': '1080p (Full HD)'},
    {'value': '720p', 'label': '720p (HD)'},
    {'value': '480p', 'label': '480p (SD)'},
    {'value': '360p', 'label': '360p (SD)'},
    {'value': '240p', 'label': '240p (Low)'},
    {'value': '144p', 'label': '144p (Very Low)'},
    {'value': 'best_muxed', 'label': 'Best Compatible (.mp4)'},
    {'value': 'audio_only', 'label': 'Audio Only'},
  ];
  @override
  void initState() {
    super.initState();
    _fetchPlaylist();
  }

  Future<void> _loadMoreVideos() async {
    if (_isLoadingMore || !_hasMoreVideos || _nextPageToken == null) return;
    if (_searchQuery.isNotEmpty) return;
    setState(() => _isLoadingMore = true);
    try {
      final details = await YoutubeService.getPlaylistDetails(
        widget.playlistUrl,
        pageToken: _nextPageToken,
      );
      if (!mounted) return;
      final videos = List<Map<String, dynamic>>.from(
        (details?['videos'] as List?)?.map(
              (e) => Map<String, dynamic>.from(e as Map),
            ) ??
            [],
      );
      setState(() {
        _videos.addAll(videos);
        _hasMoreVideos = videos.isNotEmpty;
        _nextPageToken = details?['nextPageToken'];
        _isLoadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingMore = false);
    }
  }

  Future<void> _fetchPlaylist() async {
    try {
      final details = await YoutubeService.getPlaylistDetails(
        widget.playlistUrl,
        pageSize: 50,
      );
      if (!mounted) return;
      final info = details?['info'] as Map<String, dynamic>?;
      final videos = List<Map<String, dynamic>>.from(
        (details?['videos'] as List?)?.map(
              (e) => Map<String, dynamic>.from(e as Map),
            ) ??
            [],
      );
      final note = details?['note'] as String?;
      setState(() {
        _playlistInfo = info;
        _videos = videos;
        _note = note;
        _isLoading = false;
        _nextPageToken = details?['nextPageToken'];
        _hasMoreVideos = _nextPageToken != null || videos.length >= 50;
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

  int get _selectedCount =>
      _filteredVideos.where((v) => v['selected'] == true).length;
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
    final provider = context.read<DownloadProvider>();
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    String savePath;
    try {
      savePath = settings.customDownloadPath?.isNotEmpty == true
          ? settings.customDownloadPath!
          : await PermissionService().defaultDownloadDirectory();
    } catch (e) {
      if (!mounted) return;
      ThemedSnackbar.show(
        context,
        message: L10n.isRtl(context)
            ? 'مطلوب إذن التخزين أو يتعذر تحديد المجلد الافتراضي'
            : 'Storage permission required or default directory unavailable',
        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
        icon: Icons.error_outline,
        isDarkMode: isDark,
      );
      return;
    }
    final playlistId = YoutubeService.extractPlaylistId(widget.playlistUrl) ??
        widget.playlistUrl;
    final playlistTitle = _playlistInfo?['title'] as String? ?? 'Playlist';
    final selectedVideos = _videos.where((v) => v['selected'] == true).toList();
    if (selectedVideos.isEmpty) return;
    final batchTasks = <DownloadTask>[];
    final now = DateTime.now();
    for (int i = 0; i < selectedVideos.length; i++) {
      final video = selectedVideos[i];
      final videoId = video['id'] as String? ?? '';
      if (videoId.isEmpty) continue;
      final videoTitle = video['title'] as String? ?? 'video_$videoId';
      final videoThumbnail =
          video['thumbnailUrl'] ?? video['thumbnail'] ?? video['thumbnail_url'];
      final videoUrl = YoutubeService.videoUrl(videoId);
      final ext = _qualityPreset == 'audio_only' ? 'm4a' : 'mp4';
      final displayQuality =
          _qualityPreset == 'audio_only' ? 'Audio' : _qualityPreset;
      final fileName = safeFileName('$videoTitle [$displayQuality].$ext');
      batchTasks.add(DownloadTask(
        id: '${now.microsecondsSinceEpoch}_$i',
        fileName: fileName,
        url: videoUrl,
        fileSize: 0,
        downloadedBytes: 0,
        speed: 0,
        category: _qualityPreset == 'audio_only' ? 'Audio' : 'Video',
        status: DownloadStatus.queued,
        savePath: savePath,
        localFilePath: p.join(savePath, fileName),
        tempFilePath: p.join(savePath, '.tmp_$fileName'),
        threadCount: settings.defaultThreadCount,
        chunks: List<double>.filled(settings.defaultThreadCount, 0.0),
        createdAt: now,
        updatedAt: now,
        supportsResume: true,
        speedLimitKbps: 0,
        seedingEnabled: false,
        seedingLimited: false,
        seedingLimitKbps: 500,
        downloadPageUrl: videoUrl,
        youtubeQualityPreset: _qualityPreset,
        playlistId: playlistId,
        playlistTitle: playlistTitle,
        thumbnailUrl: videoThumbnail?.toString(),
        isAppUpdate: false,
        priority: 0,
        pausedByUser: false,
        audioProgress: 0.0,
        audioSize: 0,
      ));
    }
    await provider.addBatchDownloads(
      tasks: batchTasks,
      savePath: savePath,
    );
    if (!mounted) return;
    ThemedSnackbar.show(
      context,
      message: L10n.isRtl(context)
          ? 'بدأ تحميل ${batchTasks.length} فيديو'
          : 'Downloading ${batchTasks.length} videos',
      color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
      icon: Icons.check_circle_outline,
      isDarkMode: isDark,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final glassBorder =
        isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder;
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
                                L10n.of(context, 'yt_playlist'),
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
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
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 4,
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
                              L10n.of(context, 'loading_playlist'),
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
                  else ...[
                    if (_note != null && _note!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 4,
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? AppTheme.neonAmber.withValues(alpha: 0.15)
                                : AppTheme.lightNeonAmber
                                    .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isDark
                                  ? AppTheme.neonAmber.withValues(alpha: 0.4)
                                  : AppTheme.lightNeonAmber
                                      .withValues(alpha: 0.4),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                size: 16,
                                color: isDark
                                    ? AppTheme.neonAmber
                                    : AppTheme.lightNeonAmber,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _note!,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? AppTheme.neonAmber
                                        : AppTheme.lightNeonAmber,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
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
                          TextButton.icon(
                            onPressed: () {
                              runHaptic(settings);
                              _toggleAll(
                                _selectedCount < _filteredVideos.length,
                              );
                            },
                            icon: Icon(
                              _selectedCount == _filteredVideos.length &&
                                      _filteredVideos.isNotEmpty
                                  ? Icons.deselect
                                  : Icons.select_all,
                              size: 14,
                              color: accent,
                            ),
                            label: Text(
                              _selectedCount == _filteredVideos.length &&
                                      _filteredVideos.isNotEmpty
                                  ? L10n.of(context, 'deselect_all')
                                  : L10n.of(context, 'select_all'),
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
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: TextField(
                        onChanged: (val) => setState(() => _searchQuery = val),
                        decoration: InputDecoration(
                          hintText: L10n.of(context, 'search_videos'),
                          hintStyle: TextStyle(color: mutedClr, fontSize: 13),
                          prefixIcon: Icon(
                            Icons.search,
                            size: 16,
                            color: mutedClr,
                          ),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: Icon(
                                    Icons.clear,
                                    size: 16,
                                    color: mutedClr,
                                  ),
                                  onPressed: () =>
                                      setState(() => _searchQuery = ''),
                                )
                              : null,
                          filled: true,
                          fillColor: (isDark
                                  ? AppTheme.surface
                                  : AppTheme.lightSurface)
                              .withValues(alpha: 0.6),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
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
                    Expanded(
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (ScrollNotification scrollInfo) {
                          if (scrollInfo.metrics.pixels >=
                              scrollInfo.metrics.maxScrollExtent - 200) {
                            _loadMoreVideos();
                          }
                          return false;
                        },
                        child: ListView.builder(
                          controller: scrollController,
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          itemCount: _filteredVideos.length +
                              (_hasMoreVideos && _searchQuery.isEmpty ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == _filteredVideos.length) {
                              return _isLoadingMore
                                  ? const Padding(
                                      padding: EdgeInsets.all(16),
                                      child: Center(
                                        child: SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                      ),
                                    )
                                  : const SizedBox.shrink();
                            }
                            final video = _filteredVideos[index];
                            final isSelected =
                                video['selected'] as bool? ?? true;
                            final title = video['title'] as String? ??
                                'Video ${index + 1}';
                            final duration = video['duration'] as int? ?? 0;
                            final author = video['author'] as String? ?? '';
                            final thumbnailUrl =
                                video['thumbnailUrl'] as String?;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: GlassCard.listItem(
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
                                      final originalIndex = _videos.indexOf(
                                        video,
                                      );
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
                                                  final originalIndex =
                                                      _videos.indexOf(video);
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
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: SizedBox(
                                              width: 72,
                                              height: 42,
                                              child: thumbnailUrl != null &&
                                                      thumbnailUrl.isNotEmpty
                                                  ? CachedNetworkImage(
                                                      imageUrl: thumbnailUrl
                                                              .startsWith('//')
                                                          ? 'https:$thumbnailUrl'
                                                          : thumbnailUrl,
                                                      fit: BoxFit.cover,
                                                      memCacheWidth: 144,
                                                      placeholder: (
                                                        context,
                                                        url,
                                                      ) =>
                                                          Container(
                                                        color: (isDark
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
                                                      errorWidget: (
                                                        context,
                                                        url,
                                                        error,
                                                      ) =>
                                                          Container(
                                                        color: (isDark
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
                                                      color: (isDark
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
                                            ),
                                          ),
                                          const SizedBox(width: 10),
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
                                                  overflow:
                                                      TextOverflow.ellipsis,
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
                                                      YoutubeService
                                                          .formatDuration(
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
                    ),
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
                            Row(
                              children: [
                                Text(
                                  L10n.of(context, 'quality_label'),
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
                                      color: (isDark
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
                                        menuMaxHeight: 250,
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
                                        onChanged: (val) {
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
