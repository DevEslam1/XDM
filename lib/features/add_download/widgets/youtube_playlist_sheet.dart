import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';
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
      return await showDmxModalBottomSheet<PlaylistDownloadResult>(
        context: context,
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
  final TextEditingController _searchController = TextEditingController();
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
  List<Map<String, dynamic>> _cachedFilteredVideos = const [];
  bool _filterCacheDirty = true;

  List<Map<String, dynamic>> get _filteredVideos {
    if (_filterCacheDirty) {
      if (_searchQuery.isEmpty) {
        _cachedFilteredVideos = _videos;
      } else {
        final query = _searchQuery.toLowerCase();
        _cachedFilteredVideos = _videos.where((v) {
          final title = (v['title'] as String? ?? '').toLowerCase();
          return title.contains(query);
        }).toList();
      }
      _filterCacheDirty = false;
    }
    return _cachedFilteredVideos;
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

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
        _filterCacheDirty = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingMore = false);
      final isDark = context.read<SettingsProvider>().isDarkMode;
      if (!mounted) return;
      ThemedSnackbar.show(
        context,
        message: L10n.isRtl(context)
            ? 'تعذر تحميل المزيد من الفيديوهات'
            : 'Could not load more videos',
        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
        icon: Icons.error_outline,
        isDarkMode: isDark,
      );
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
        _filterCacheDirty = true;
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
      _filterCacheDirty = true;
    });
  }

  void _toggleVideo(Map<String, dynamic> video, bool newVal) {
    final originalIndex = _videos.indexOf(video);
    if (originalIndex != -1) {
      setState(() {
        _videos[originalIndex] = {
          ...video,
          'selected': newVal,
        };
        _filterCacheDirty = true;
      });
    }
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
    Navigator.of(context).pop(PlaylistDownloadResult(
      selectedVideos: selectedVideos,
      qualityPreset: _qualityPreset,
      playlistTitle: playlistTitle,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isAmoled = settings.isAmoledMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final amber = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final textClr = AppTheme.textPrimaryOf(isDark);
    final secClr = AppTheme.textSecondaryOf(isDark);
    final mutedClr = AppTheme.textMutedOf(isDark);
    final hairline = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);
    final panelBg = AppTheme.panelBg(isDark, isAmoled: isAmoled);
    final showFooter = !_isLoading && _errorMessage == null;

    return DmxSheetContainer(
      scrollable: false,
      maxHeightFraction: 0.92,
      isDark: isDark,
      isAmoled: isAmoled,
      accentColor: redClr,
      padding: EdgeInsets.zero,
      header: DmxSheetHeader(
        title: L10n.of(context, 'yt_playlist'),
        subtitle: _playlistInfo?['title'] as String?,
        icon: Icons.playlist_play_rounded,
        accentColor: redClr,
        isDark: isDark,
      ),
      footer: showFooter
          ? _buildStickyFooter(
              context: context,
              isDark: isDark,
              isAmoled: isAmoled,
              accent: accent,
              amber: amber,
              textClr: textClr,
              secClr: secClr,
              mutedClr: mutedClr,
              hairline: hairline,
              panelBg: panelBg,
            )
          : null,
      child: Column(
        children: [
          // Legal warning banner
          Padding(
            padding: const EdgeInsets.fromLTRB(
              DmxTokens.sheetHorizontalPadding,
              10,
              DmxTokens.sheetHorizontalPadding,
              6,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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
                      L10n.of(context, 'loading_playlist'),
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
                          color: redClr.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.error_outline_rounded,
                          color: redClr,
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
                        onPressed: () {
                          setState(() {
                            _isLoading = true;
                            _errorMessage = null;
                            _videos = [];
                            _playlistInfo = null;
                            _filterCacheDirty = true;
                          });
                          _fetchPlaylist();
                        },
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
          else ...[
            if (_note != null && _note!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  DmxTokens.sheetHorizontalPadding,
                  2,
                  DmxTokens.sheetHorizontalPadding,
                  4,
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: amber.withValues(alpha: isDark ? 0.14 : 0.10),
                    borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
                    border: Border.all(
                      color: amber.withValues(alpha: 0.35),
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline_rounded, size: 16, color: amber),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _note!,
                          style: TextStyle(
                            fontFamily: AppTheme.fontBody,
                            fontSize: 12,
                            color: amber,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Playlist metadata & Select All bar
            Padding(
              padding: const EdgeInsets.fromLTRB(
                DmxTokens.sheetHorizontalPadding,
                4,
                14,
                4,
              ),
              child: Row(
                children: [
                  if (_playlistInfo?['author'] != null) ...[
                    Icon(Icons.person_outline_rounded,
                        size: 14, color: mutedClr),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        _playlistInfo!['author'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AppTheme.fontBody,
                          color: mutedClr,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Icon(
                    Icons.video_library_outlined,
                    size: 14,
                    color: mutedClr,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${_filteredVideos.length}${_searchQuery.isNotEmpty ? ' / ${_videos.length}' : ''} videos',
                    style: AppTheme.dataStyle(
                      isDark: isDark,
                      size: 11,
                      color: mutedClr,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      runHaptic(settings);
                      _toggleAll(_selectedCount < _filteredVideos.length);
                    },
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: Icon(
                      _selectedCount == _filteredVideos.length &&
                              _filteredVideos.isNotEmpty
                          ? Icons.deselect_rounded
                          : Icons.select_all_rounded,
                      size: 15,
                      color: accent,
                    ),
                    label: Text(
                      _selectedCount == _filteredVideos.length &&
                              _filteredVideos.isNotEmpty
                          ? L10n.of(context, 'deselect_all')
                          : L10n.of(context, 'select_all'),
                      style: TextStyle(
                        fontFamily: AppTheme.fontDisplay,
                        color: accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Search bar
            Padding(
              padding: const EdgeInsets.fromLTRB(
                DmxTokens.sheetHorizontalPadding,
                4,
                DmxTokens.sheetHorizontalPadding,
                10,
              ),
              child: TextField(
                controller: _searchController,
                onChanged: (val) => setState(() {
                  _searchQuery = val;
                  _filterCacheDirty = true;
                }),
                decoration: InputDecoration(
                  hintText: L10n.of(context, 'search_videos'),
                  hintStyle: TextStyle(
                    fontFamily: AppTheme.fontBody,
                    color: mutedClr,
                    fontSize: 13,
                  ),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: mutedClr,
                  ),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear, size: 17, color: mutedClr),
                          onPressed: () => setState(() {
                            _searchController.clear();
                            _searchQuery = '';
                            _filterCacheDirty = true;
                          }),
                        )
                      : null,
                  filled: true,
                  fillColor: panelBg,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                    borderSide: BorderSide(color: hairline, width: 0.8),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                    borderSide: BorderSide(color: hairline, width: 0.8),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                    borderSide: BorderSide(color: accent, width: 1.2),
                  ),
                ),
                style: TextStyle(
                  fontFamily: AppTheme.fontBody,
                  color: textClr,
                  fontSize: 13,
                ),
              ),
            ),

            Divider(height: 1, thickness: 0.8, color: hairline),

            // Video list
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
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(
                    DmxTokens.sheetHorizontalPadding,
                    10,
                    DmxTokens.sheetHorizontalPadding,
                    12,
                  ),
                  itemCount: _filteredVideos.length +
                      (_hasMoreVideos && _searchQuery.isEmpty ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == _filteredVideos.length) {
                      return _isLoadingMore
                          ? Padding(
                              padding: const EdgeInsets.all(16),
                              child: Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: accent,
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink();
                    }
                    final video = _filteredVideos[index];
                    return _buildVideoRow(
                      video: video,
                      index: index,
                      isDark: isDark,
                      isAmoled: isAmoled,
                      accent: accent,
                      textClr: textClr,
                      secClr: secClr,
                      mutedClr: mutedClr,
                      hairline: hairline,
                      panelBg: panelBg,
                    );
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVideoRow({
    required Map<String, dynamic> video,
    required int index,
    required bool isDark,
    required bool isAmoled,
    required Color accent,
    required Color textClr,
    required Color secClr,
    required Color mutedClr,
    required Color hairline,
    required Color panelBg,
  }) {
    final isSelected = video['selected'] as bool? ?? true;
    final title = video['title'] as String? ?? 'Video ${index + 1}';
    final duration = video['duration'] as int? ?? 0;
    final author = video['author'] as String? ?? '';
    final thumbnailUrl = video['thumbnailUrl'] as String?;

    return RepaintBoundary(
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.surfaceColor(isDark,
                  isAmoled: isAmoled, elevated: false)
              : panelBg.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
          border: Border.all(
            color: isSelected
                ? accent.withValues(alpha: isDark ? 0.32 : 0.28)
                : hairline,
            width: 0.8,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _toggleVideo(video, !isSelected),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: isSelected,
                      activeColor: accent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                      side: BorderSide(color: hairline, width: 1.2),
                      onChanged: (val) {
                        if (val != null) _toggleVideo(video, val);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
                    child: SizedBox(
                      width: 72,
                      height: 42,
                      child: thumbnailUrl != null && thumbnailUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: thumbnailUrl.startsWith('//')
                                  ? 'https:$thumbnailUrl'
                                  : thumbnailUrl,
                              fit: BoxFit.cover,
                              memCacheWidth: 144,
                              memCacheHeight: 84,
                              placeholder: (_, __) =>
                                  _thumbPlaceholder(panelBg, mutedClr),
                              errorWidget: (_, __, ___) =>
                                  _thumbPlaceholder(panelBg, mutedClr),
                            )
                          : _thumbPlaceholder(panelBg, mutedClr),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontFamily: AppTheme.fontDisplay,
                            color: isSelected ? textClr : secClr,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            decoration:
                                isSelected ? null : TextDecoration.lineThrough,
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
                                    fontFamily: AppTheme.fontBody,
                                    color: mutedClr,
                                    fontSize: 11,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Icon(
                              Icons.access_time_rounded,
                              size: 11,
                              color: mutedClr,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              YoutubeService.formatDuration(duration),
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
                  const SizedBox(width: 6),
                  Text(
                    '#${index + 1}',
                    style: AppTheme.dataStyle(
                      isDark: isDark,
                      size: 11,
                      color: mutedClr,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumbPlaceholder(Color bg, Color mutedClr) {
    return Container(
      color: bg,
      alignment: Alignment.center,
      child: Icon(Icons.play_circle_outline_rounded, color: mutedClr, size: 22),
    );
  }

  Widget _buildStickyFooter({
    required BuildContext context,
    required bool isDark,
    required bool isAmoled,
    required Color accent,
    required Color amber,
    required Color textClr,
    required Color secClr,
    required Color mutedClr,
    required Color hairline,
    required Color panelBg,
  }) {
    final sheetSurface = AppTheme.sheetSurface(isDark, isAmoled: isAmoled);
    final isRtl = L10n.isRtl(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 1, thickness: 0.8, color: hairline),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            DmxTokens.sheetHorizontalPadding,
            12,
            DmxTokens.sheetHorizontalPadding,
            16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    L10n.of(context, 'quality_label'),
                    style: AppTheme.microLabel(isDark: isDark, color: secClr),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: panelBg,
                        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                        border: Border.all(color: hairline, width: 0.8),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          dropdownColor: sheetSurface,
                          menuMaxHeight: 250,
                          value: _qualityPreset,
                          isExpanded: true,
                          icon: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: secClr,
                            size: 20,
                          ),
                          style: TextStyle(
                            fontFamily: AppTheme.fontDisplay,
                            color: textClr,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                          items: _qualityOptions.map((opt) {
                            return DropdownMenuItem<String>(
                              value: opt['value'],
                              child: Text(
                                opt['label']!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() => _qualityPreset = val);
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
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline_rounded, size: 13, color: amber),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _qualityPreset == 'best_combined'
                              ? (isRtl
                                  ? 'ملاحظة: سيتم دمج أفضل جودة صوت وصورة تلقائياً.'
                                  : 'Note: Best video and audio will be auto-merged.')
                              : (isRtl
                                  ? 'ملاحظة: سيتم تحميل أفضل جودة مدمجة (غالباً 360p).'
                                  : 'Note: Best merged quality will be downloaded (usually 360p).'),
                          style: TextStyle(
                            fontFamily: AppTheme.fontBody,
                            color: amber,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _selectedCount == 0 ? null : _startBatchDownload,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text(
                  isRtl
                      ? 'تحميل $_selectedCount فيديو'
                      : 'DOWNLOAD $_selectedCount VIDEO${_selectedCount != 1 ? 'S' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                  backgroundColor: accent,
                  foregroundColor: AppTheme.inkOn(accent),
                  disabledBackgroundColor: accent.withValues(alpha: 0.35),
                  disabledForegroundColor:
                      AppTheme.inkOn(accent).withValues(alpha: 0.7),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                  ),
                ),
              ),
              if (_selectedCount == 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    isRtl
                        ? 'يرجى تحديد فيديو واحد على الأقل للتحميل'
                        : 'Select at least 1 video to start download',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: AppTheme.fontBody,
                      color: mutedClr,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
