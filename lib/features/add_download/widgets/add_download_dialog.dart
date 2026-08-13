import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/url_utils.dart';
import '../../../core/utils/bencode_decoder.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/constants.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/services/download_engine.dart';
import '../../../core/di/injection.dart';
import '../../../core/services/site_intelligence/site_intelligence_service.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/models/download_task.dart';
import '../../settings/provider/settings_provider.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../widgets/media_quality_sheet.dart';
import '../widgets/youtube_playlist_sheet.dart';
import 'package:logging/logging.dart';
import '../../../shared/mixins/pausable_loop_animation.dart';
import '../../../shared/design/dmx_design.dart';

class AddDownloadDialog extends StatefulWidget {
  final String? prefilledUrl;
  final String? prefilledName;
  final String? downloadPageUrl;
  final bool isShareLaunch;
  const AddDownloadDialog({
    super.key,
    this.prefilledUrl,
    this.prefilledName,
    this.downloadPageUrl,
    this.isShareLaunch = false,
  });
  static Future<T?> show<T>(
    BuildContext context, {
    String? prefilledUrl,
    String? prefilledName,
    String? downloadPageUrl,
    bool isShareLaunch = false,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: true,
      builder: (context) => AddDownloadDialog(
        prefilledUrl: prefilledUrl,
        prefilledName: prefilledName,
        downloadPageUrl: downloadPageUrl,
        isShareLaunch: isShareLaunch,
      ),
    );
  }

  @override
  State<AddDownloadDialog> createState() => _AddDownloadDialogState();
  static final Map<String, DateTime> _recentlyAddedUrls = {};
  static bool wasRecentlyAdded(String url) {
    _pruneRecentUrls();
    return _recentlyAddedUrls.containsKey(url.trim().toLowerCase());
  }

  static void recordAddedUrl(String url) {
    _recentlyAddedUrls[url.trim().toLowerCase()] = DateTime.now();
  }

  static void _pruneRecentUrls() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
    _recentlyAddedUrls.removeWhere((_, time) => time.isBefore(cutoff));
  }
}

class _AddDownloadDialogState extends State<AddDownloadDialog>
    with
        HapticHelper,
        TickerProviderStateMixin,
        WidgetsBindingObserver,
        PausableLoopAnimation<AddDownloadDialog> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _referrerController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _extController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  final FocusNode _urlFocus = FocusNode();
  String _selectedCategory = 'Auto';
  int _selectedThreads = 5;
  bool _wifiOnly = false;
  bool _retry = true;

  bool _isScheduled = false;
  bool _showAdvanced = false;
  DateTime? _scheduledDateTime;
  bool _userEditedName = false;
  String? _resolvedYoutubeQualityPreset;
  String? _resolvedAudioUrl;
  int? _resolvedAudioSize;
  String? _resolvedThumbnailUrl;
  bool _isMetadataResolved = false;
  bool _isResolvingLink = false;
  bool _isSubmitting = false;
  String _resolvedFileName = '';
  int _resolvedFileSize = 0;
  int? _resolvedTorrentId;
  String _resolvedCategory = 'Auto';
  List<Map<String, dynamic>> _torrentFiles = [];
  String _lastCheckedUrl = '';
  UrlAnalysisResult? _urlAnalysis;
  Timer? _ytDebounceTimer;
  Timer? _analysisDebounceTimer;
  late final AnimationController _scanController;
  @override
  AnimationController get loopController => _scanController;

  final List<String> _categories = [
    'Auto',
    'Video',
    'Audio',
    'Document',
    'Archive',
    'APK',
    'Other',
  ];
  final List<int> _threadsList = kAvailableThreadOptions;

  bool get _isTorrentOrMagnet {
    final raw = _urlController.text.trim();
    if (raw.isEmpty) return false;
    final lower = raw.toLowerCase();
    return lower.startsWith('magnet:') ||
        isMagnetUrl(raw) ||
        isTorrentFileUrl(raw) ||
        lower.endsWith('.torrent') ||
        lower.contains('.torrent?');
  }

  String _composeFullName(String name, String ext) {
    if (ext.isEmpty) return name;
    final dotExt = '.${ext.toLowerCase()}';
    if (name.toLowerCase().endsWith(dotExt)) return name;
    return '$name.$ext';
  }

  @override
  void initState() {
    super.initState();
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    startPausableLoop();
    final settings = context.read<SettingsProvider>();
    if (_threadsList.contains(settings.defaultThreadCount)) {
      _selectedThreads = settings.defaultThreadCount;
    }
    _wifiOnly = settings.wifiOnly;

    _loadDefaultPath();
    _urlController.addListener(_onUrlChanged);
    if (widget.prefilledUrl != null && widget.prefilledUrl!.trim().isNotEmpty) {
      _urlController.text = widget.prefilledUrl!;
      final url = widget.prefilledUrl!.trim();
      if (url.toLowerCase().startsWith('magnet:')) {
        final parsed = parseMagnetUrl(url);
        final dnName = parsed['name'] ?? 'Torrent Download';
        _setNameAndExt(dnName);
        _resolvedFileName = dnName;
        _resolvedCategory = 'Archive';
        _selectedCategory = 'Archive';
        _isMetadataResolved = true;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resolveLinkMetadata();
      });
    }
    if (widget.prefilledName != null &&
        widget.prefilledName!.trim().isNotEmpty) {
      _setNameAndExt(widget.prefilledName!);
      _resolvedFileName = widget.prefilledName!;
      _isMetadataResolved = true;
    }
  }

  void _setNameAndExt(String fullName) {
    final ext = p.extension(fullName);
    final name = p.basenameWithoutExtension(fullName);
    _nameController.text = name;
    _extController.text = ext.replaceFirst('.', '');
  }

  void _onUrlChanged() {
    final url = _urlController.text.trim();
    if (url == _lastCheckedUrl) return;
    _lastCheckedUrl = url;
    _ytDebounceTimer?.cancel();
    _analysisDebounceTimer?.cancel();
    if (url.isNotEmpty) {
      _analysisDebounceTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) {
          setState(() {
            _urlAnalysis = SiteIntelligenceService().analyzeUrl(url);
          });
        }
      });
    } else {
      _urlAnalysis = null;
    }
    if (url.toLowerCase().startsWith('magnet:')) {
      final parsed = parseMagnetUrl(url);
      final dnName = parsed['name'] ?? 'Torrent Download';
      setState(() {
        if (!_userEditedName) {
          _setNameAndExt(dnName);
        }
        _resolvedFileName = _nameController.text.isNotEmpty
            ? _composeFullName(_nameController.text, _extController.text)
            : dnName;
        _resolvedCategory = 'Archive';
        _selectedCategory = 'Archive';
        _isMetadataResolved = true;
      });
    } else if (YoutubeService.isExtractableMediaUrl(url)) {
      if (!_isResolvingLink && !_isMetadataResolved) {
        _ytDebounceTimer = Timer(const Duration(milliseconds: 800), () {
          if (_urlController.text.trim() == url && mounted) {
            _resolveLinkMetadata();
          }
        });
      }
    } else {
      if (_isMetadataResolved &&
          _torrentFiles.isEmpty &&
          _resolvedFileSize == 0 &&
          _resolvedCategory == 'Archive') {
        setState(() {
          _isMetadataResolved = false;
          _resolvedFileName = '';
          _resolvedTorrentId = null;
          _resolvedAudioUrl = null;
          _resolvedAudioSize = null;
          _nameController.clear();
          _extController.clear();
          _userEditedName = false;
        });
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadDefaultPath() async {
    final settings = context.read<SettingsProvider>();
    try {
      final path = settings.customDownloadPath?.isNotEmpty == true
          ? settings.customDownloadPath!
          : await PermissionService().defaultDownloadDirectory();
      if (!mounted) return;
      if (_pathController.text.isEmpty) _pathController.text = path;
    } catch (e) {
      if (!mounted) return;
      ThemedSnackbar.show(
        context,
        message: L10n.isRtl(context)
            ? 'مطلوب إذن التخزين أو يتعذر تحديد المجلد الافتراضي'
            : 'Storage permission required or default directory unavailable',
        color: context.read<SettingsProvider>().isDarkMode
            ? AppTheme.neonRed
            : AppTheme.lightNeonRed,
        icon: Icons.error_outline,
        isDarkMode: context.read<SettingsProvider>().isDarkMode,
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = context.read<SettingsProvider>();
    if (settings.batterySaverMode && _selectedThreads != 2) {
      _selectedThreads = 2;
    }
  }

  @override
  void dispose() {
    _urlController.removeListener(_onUrlChanged);
    _urlController.dispose();
    _referrerController.dispose();
    _nameController.dispose();
    _extController.dispose();
    _pathController.dispose();
    _urlFocus.dispose();
    _ytDebounceTimer?.cancel();
    _analysisDebounceTimer?.cancel();
    stopPausableLoop();
    _scanController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      if (!mounted) return;
      final text = data.text!.trim();
      _urlController.text = text;
      _urlController.selection = TextSelection.fromPosition(
        TextPosition(offset: _urlController.text.length),
      );
      if (text.isNotEmpty) {
        _resolveLinkMetadata();
      }
    }
  }

  void _updateSelectedTorrentSize() {
    if (_torrentFiles.isEmpty) return;
    final selectedTotal = _torrentFiles
        .where((f) => f['selected'] == true)
        .fold<int>(0, (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0));
    setState(() => _resolvedFileSize = selectedTotal);
  }

  Future<void> _pickTorrentFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['torrent'],
      );
      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        _urlController.text = filePath;
        final file = File(filePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final meta = await compute(BencodeDecoder.parseTorrentBytes, bytes);
          if (!mounted) return;
          if (meta != null) {
            setState(() {
              _resolvedFileName = meta['name'] as String? ?? '';
              _resolvedCategory = categoryFromFileName(_resolvedFileName);
              _torrentFiles = (meta['files'] as List? ?? []).map((f) {
                final fileMap = f as Map;
                return {
                  'name': fileMap['name'] as String? ?? '',
                  'length': fileMap['length'] as int? ?? 0,
                  'selected': true,
                  'priority': 4,
                  'downloadedBytes': 0,
                  'speed': 0.0,
                };
              }).toList();
              _updateSelectedTorrentSize();
              _isMetadataResolved = true;
              if (!_userEditedName) _setNameAndExt(_resolvedFileName);
              if (_categories.contains(_resolvedCategory)) {
                _selectedCategory = _resolvedCategory;
              }
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Error picking torrent file: $e');
    }
  }

  Future<void> _resolveLinkMetadata() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ThemedSnackbar.show(
        context,
        message:
            L10n.isRtl(context) ? 'أدخل الرابط أولاً' : 'Enter a URL first',
        color: AppTheme.neonRed,
        icon: Icons.error_outline,
        isDarkMode: context.read<SettingsProvider>().isDarkMode,
      );
      return;
    }
    if (YoutubeService.isPlaylistUrl(url)) {
      final isMixed = YoutubeService.isYoutubeVideoUrl(url);
      if (isMixed && mounted) {
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) {
            final isDark = context.read<SettingsProvider>().isDarkMode;
            final isRtl = L10n.isRtl(context);
            return AlertDialog(
              backgroundColor:
                  isDark ? AppTheme.surface : AppTheme.lightSurface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: Text(
                isRtl ? 'ماذا تريد تحميل؟' : 'What do you want to download?',
                style: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Text(
                isRtl
                    ? 'هذا الرابط يحتوي على فيديو وقائمة تشغيل.'
                    : 'This link contains both a single video and a playlist.',
                style: TextStyle(
                  color: isDark ? Colors.white70 : Colors.black54,
                  fontSize: 13,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'video'),
                  child: Text(
                    isRtl ? 'فيديو واحد فقط' : 'Single Video',
                    style: const TextStyle(
                      color: Colors.blue,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'playlist'),
                  child: Text(
                    isRtl ? 'قائمة التشغيل كاملة' : 'Entire Playlist',
                    style: const TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            );
          },
        );
        if (!mounted) return;
        if (choice == 'playlist') {
          final result = await YoutubePlaylistSheet.show(context, url);
          if (result != null && mounted) {
            final isDark = context.read<SettingsProvider>().isDarkMode;
            ThemedSnackbar.show(
              context,
              message: L10n.isRtl(context)
                  ? 'تم إضافة ${result.selectedVideos.length} فيديو'
                  : '${result.selectedVideos.length} videos enqueued',
              color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
              icon: Icons.playlist_add_check,
              isDarkMode: isDark,
            );
            if (mounted) Navigator.pop(context);
          }
          return;
        } else if (choice != 'video') {
          return;
        }
      } else if (!isMixed && mounted) {
        final result = await YoutubePlaylistSheet.show(context, url);
        if (result != null && mounted) {
          final isDark = context.read<SettingsProvider>().isDarkMode;
          ThemedSnackbar.show(
            context,
            message: L10n.isRtl(context)
                ? 'تم إضافة ${result.selectedVideos.length} فيديو'
                : '${result.selectedVideos.length} videos enqueued',
            color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
            icon: Icons.playlist_add_check,
            isDarkMode: isDark,
          );
          if (mounted) Navigator.pop(context);
        }
        return;
      }
    }
    if (YoutubeService.isExtractableMediaUrl(url)) {
      if (!mounted) return;
      final stream = await YoutubeQualitySheet.show(context, url);
      if (!mounted) return;
      if (stream != null) {
        final title = stream['title'] as String? ?? 'Media Download';
        final ext = stream['ext'] as String? ?? 'mp4';
        final streamUrl = stream['src'] as String;
        final streamSize = (stream['size'] as num?)?.toInt() ?? 0;
        final audioUrl = stream['audioSrc'] as String?;
        final audioSize = (stream['audioSize'] as num?)?.toInt();
        final streamType = stream['type'] as String? ?? 'muxed';
        final thumbnailUrl = stream['thumbnailUrl'] as String?;
        final qualityPreset =
            streamType == 'audio' ? 'audio_only' : stream['quality'] as String?;
        final category = streamType == 'audio' ? 'Audio' : 'Video';
        final fileName = safeFileName('$title.$ext');
        final provider = context.read<DownloadProvider>();
        final settings = context.read<SettingsProvider>();
        final savePath = _pathController.text.trim().isNotEmpty
            ? _pathController.text.trim()
            : settings.customDownloadPath ?? '';
        await provider.addDownload(
          name: fileName,
          url: streamUrl,
          size: streamSize,
          category: category,
          savePath: savePath,
          threadCount: _selectedThreads,
          downloadPageUrl: url,
          youtubeQualityPreset: qualityPreset,
          mergedAudioUrl: audioUrl,
          audioSize: audioSize ?? 0,
          thumbnailUrl: thumbnailUrl,
        );
        if (!mounted) return;
        if (provider.lastError != null) {
          final isDark = context.read<SettingsProvider>().isDarkMode;
          ThemedSnackbar.show(
            context,
            message: provider.lastError!,
            color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
            icon: Icons.error_outline,
            isDarkMode: isDark,
          );
          return;
        }
        final isDark = context.read<SettingsProvider>().isDarkMode;
        ThemedSnackbar.show(
          context,
          message: L10n.isRtl(context) ? 'تم بدء التحميل' : 'Download started',
          color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          icon: Icons.check_circle_outline,
          isDarkMode: isDark,
        );
        Navigator.pop(context);
        return;
      }
    }
    if (!isValidTransmissionUrl(url)) {
      ThemedSnackbar.show(
        context,
        message: L10n.isRtl(context) ? 'رابط غير صالح' : 'Invalid URL',
        color: AppTheme.neonRed,
        icon: Icons.error_outline,
        isDarkMode: context.read<SettingsProvider>().isDarkMode,
      );
      return;
    }
    setState(() {
      _isResolvingLink = true;
      _isMetadataResolved = false;
      _resolvedTorrentId = null;
      _torrentFiles = [];
    });
    try {
      final settings = context.read<SettingsProvider>();
      if (url.toLowerCase().startsWith('magnet:')) {
        final parsed = parseMagnetUrl(url);
        final rawDnName = parsed['name'] ?? 'Torrent Download';
        final dnName = safeFileName(rawDnName);
        if (mounted) {
          setState(() {
            if (!_userEditedName) _setNameAndExt(dnName);
            _resolvedFileName = dnName;
            final cat = categoryFromFileName(dnName);
            _resolvedCategory = cat != 'Other' ? cat : 'Video';
            if (_categories.contains(_resolvedCategory)) {
              _selectedCategory = _resolvedCategory;
            }
          });
        }
      }
      String? localFilePath;
      if (url.toLowerCase().startsWith('file://')) {
        try {
          localFilePath = Uri.parse(url).toFilePath();
        } catch (e, st) {
          Logger('add_download_dialog')
              .warning('[add_download_dialog] operation failed', e, st);
          localFilePath = url.replaceFirst(
            RegExp(r'^file://', caseSensitive: false),
            '',
          );
        }
      } else if (url.toLowerCase().endsWith('.torrent') ||
          File(url).existsSync()) {
        localFilePath = url;
      }
      if (localFilePath != null) {
        final file = File(localFilePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final meta = await compute(BencodeDecoder.parseTorrentBytes, bytes);
          if (!mounted) return;
          if (meta != null) {
            setState(() {
              _resolvedFileName = meta['name'] ?? '';
              _resolvedFileSize = meta['length'] ?? 0;
              _resolvedCategory = 'Archive';
              _torrentFiles = (meta['files'] as List? ?? []).map((f) {
                final fileMap = f as Map;
                return {
                  'name': fileMap['name'] as String? ?? '',
                  'length': fileMap['length'] as int? ?? 0,
                  'selected': true,
                  'priority': 4,
                  'downloadedBytes': 0,
                  'speed': 0.0,
                };
              }).toList();
              _isMetadataResolved = true;
              if (!_userEditedName) _setNameAndExt(_resolvedFileName);
              _selectedCategory = 'Archive';
            });
            return;
          }
        }
      }
      final engine = getIt<DownloadEngine>();
      final nameForReq = _nameController.text.trim().isNotEmpty
          ? _composeFullName(
              _nameController.text.trim(), _extController.text.trim())
          : null;
      final DownloadMetadata meta = await engine.resolveMetadata(
        url: url,
        requestedFileName: nameForReq,
        customUserAgent: settings.customUserAgent,
        bypassSSL: settings.bypassSSL,
      );
      if (!mounted) return;
      setState(() {
        _resolvedFileName = meta.fileName;
        _resolvedFileSize = meta.fileSize;
        _resolvedTorrentId = meta.torrentId;
        _resolvedCategory = meta.category;
        _torrentFiles = meta.torrentFiles ?? [];
        _isMetadataResolved = true;
        if (!_userEditedName) _setNameAndExt(_resolvedFileName);
        if (_categories.contains(_resolvedCategory)) {
          _selectedCategory = _resolvedCategory;
        }
      });
    } catch (e) {
      if (mounted) {
        ThemedSnackbar.show(
          context,
          message: 'Error: $e',
          color: AppTheme.neonRed,
          icon: Icons.error_outline,
          isDarkMode: context.read<SettingsProvider>().isDarkMode,
        );
      }
    } finally {
      if (mounted) setState(() => _isResolvingLink = false);
    }
  }

  Future<void> _handleDuplicateOrSubmit() async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final provider = context.read<DownloadProvider>();
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final urls = _urlController.text
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (urls.length > 1) {
      var addedCount = 0;
      var duplicateCount = 0;
      var invalidCount = 0;
      for (final singleUrl in urls) {
        if (!isValidTransmissionUrl(singleUrl)) {
          invalidCount++;
          continue;
        }
        if (AddDownloadDialog.wasRecentlyAdded(singleUrl)) {
          duplicateCount++;
          continue;
        }
        final enteredName = _nameController.text.trim();
        final enteredExt = _extController.text.trim();
        final String fullName = _composeFullName(enteredName, enteredExt);
        String singleName;
        if (fullName.isNotEmpty) {
          final safeName = safeFileName(fullName);
          final ext = p.extension(safeName);
          final base = p.basenameWithoutExtension(safeName);
          singleName = addedCount > 0 ? '${base}_$addedCount$ext' : safeName;
        } else {
          singleName = fileNameFromUrl(singleUrl);
        }
        try {
          await provider.addDownload(
            name: singleName,
            url: singleUrl,
            size: _isMetadataResolved ? _resolvedFileSize : 0,
            category: _selectedCategory == 'Auto' ? '' : _selectedCategory,
            savePath: _pathController.text.trim(),
            threadCount: _selectedThreads,
            scheduledAt: _isScheduled ? _scheduledDateTime : null,
            torrentFiles: _torrentFiles.isNotEmpty ? _torrentFiles : null,
            downloadPageUrl:
                widget.downloadPageUrl ?? _referrerController.text.trim(),
            youtubeQualityPreset: _resolvedYoutubeQualityPreset,
            torrentId: _resolvedTorrentId,
            mergedAudioUrl: _resolvedAudioUrl,
            audioSize: _resolvedAudioSize ?? 0,
            thumbnailUrl: _resolvedThumbnailUrl,
          );
          addedCount++;
          AddDownloadDialog.recordAddedUrl(singleUrl);
        } catch (e) {
          if (!mounted) return;
          ThemedSnackbar.show(
            context,
            message: '$singleUrl: $e',
            color: redClr,
            icon: Icons.error_outline,
            isDarkMode: isDark,
          );
        }
      }
      if (!mounted) return;
      final dupParts = <String>[];
      if (duplicateCount > 0) {
        dupParts.add(isRtl
            ? '$duplicateCount مكرر'
            : '$duplicateCount duplicate${duplicateCount != 1 ? 's' : ''}');
      }
      if (invalidCount > 0) {
        dupParts
            .add(isRtl ? '$invalidCount غير صالح' : '$invalidCount invalid');
      }
      if (addedCount > 0) {
        final dupMsg = dupParts.isNotEmpty
            ? (isRtl
                ? ' (${dupParts.join('، ')} تم تخطيه)'
                : ' (${dupParts.join(', ')} skipped)')
            : '';
        ThemedSnackbar.show(
          context,
          message:
              (isRtl ? 'تم إضافة $addedCount رابط' : '$addedCount URLs added') +
                  dupMsg,
          color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          icon: Icons.check_circle_outline,
          isDarkMode: isDark,
        );
        if (mounted) setState(() => _isSubmitting = false);
        Navigator.pop(context);
      } else if (dupParts.isNotEmpty) {
        ThemedSnackbar.show(
          context,
          message: isRtl
              ? 'تم تخطي ${dupParts.join('، ')}'
              : 'Skipped ${dupParts.join(', ')}',
          color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
          icon: Icons.info_outline,
          isDarkMode: isDark,
        );
        if (mounted) setState(() => _isSubmitting = false);
      }
      return;
    }
    final enteredName = _nameController.text.trim();
    final enteredExt = _extController.text.trim();
    final String fullEnteredName = _composeFullName(enteredName, enteredExt);
    final singleUrl = urls.isNotEmpty ? urls.first : '';
    final finalFileName = fullEnteredName.isNotEmpty
        ? safeFileName(fullEnteredName)
        : fileNameFromUrl(singleUrl);
    final int finalSize = _isMetadataResolved ? _resolvedFileSize : 0;
    DownloadTask? duplicateTask;
    final trimmedUrl = singleUrl.trim();
    for (final task in provider.tasks) {
      final normalizedTaskUrl =
          task.url.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
      final normalizedNewUrl =
          trimmedUrl.toLowerCase().replaceAll(RegExp(r'/+$'), '');
      final isSameUrl = normalizedTaskUrl == normalizedNewUrl;
      final isSameNameAndSize = finalSize > 0 &&
          task.fileName.toLowerCase() == finalFileName.toLowerCase() &&
          task.fileSize == finalSize;
      if (isSameUrl || isSameNameAndSize) {
        duplicateTask = task;
        break;
      }
    }
    if (duplicateTask != null) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            backgroundColor: isDark ? AppTheme.surface : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(
                color:
                    isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
              ),
            ),
            title: Text(
              isRtl ? 'ملف مكرر' : 'DUPLICATE',
              style: TextStyle(
                color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            content: Text(
              isRtl
                  ? 'يوجد ملف بنفس الاسم والحجم. اختر إجراء:'
                  : 'A file with the same name and size exists. Choose an action:',
              style: TextStyle(
                color: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary,
                fontSize: 13,
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actionsOverflowButtonSpacing: 8,
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: blueClr.withValues(alpha: 0.1),
                  side: BorderSide(color: blueClr),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () async {
                  triggerHaptic(settings);
                  Navigator.pop(dialogContext);
                  try {
                    await provider.updateTaskUrlAndResume(
                      duplicateTask!.id,
                      singleUrl,
                    );
                    if (!mounted) return;
                    if (!context.mounted) return;
                    ThemedSnackbar.show(
                      context,
                      message: isRtl ? 'تم تحديث الرابط' : 'Link updated',
                      color:
                          isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                      icon: Icons.check_circle_outline,
                      isDarkMode: isDark,
                    );
                    if (mounted) setState(() => _isSubmitting = false);
                    Navigator.pop(context);
                  } catch (e) {
                    if (!mounted) return;
                    if (!context.mounted) return;
                    ThemedSnackbar.show(
                      context,
                      message: e.toString(),
                      color: redClr,
                      icon: Icons.error_outline,
                      isDarkMode: isDark,
                    );
                    if (mounted) setState(() => _isSubmitting = false);
                  }
                },
                child: Text(
                  isRtl ? 'تحديث الرابط' : 'UPDATE LINK',
                  style: TextStyle(
                    color: blueClr,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      (isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet)
                          .withValues(alpha: 0.1),
                  side: BorderSide(
                    color:
                        isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () async {
                  triggerHaptic(settings);
                  Navigator.pop(dialogContext);
                  try {
                    await provider.startOverTask(duplicateTask!.id, singleUrl);
                    if (!mounted) return;
                    if (!context.mounted) return;
                    ThemedSnackbar.show(
                      context,
                      message: isRtl ? 'بدأ من جديد' : 'Started over',
                      color:
                          isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                      icon: Icons.refresh,
                      isDarkMode: isDark,
                    );
                    if (mounted) setState(() => _isSubmitting = false);
                    Navigator.pop(context);
                  } catch (e) {
                    if (!mounted) return;
                    if (!context.mounted) return;
                    ThemedSnackbar.show(
                      context,
                      message: e.toString(),
                      color: redClr,
                      icon: Icons.error_outline,
                      isDarkMode: isDark,
                    );
                    if (mounted) setState(() => _isSubmitting = false);
                  }
                },
                child: Text(
                  isRtl ? 'بدء من جديد' : 'START OVER',
                  style: TextStyle(
                    color:
                        isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
                          .withValues(alpha: 0.1),
                  side: BorderSide(
                    color:
                        isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () async {
                  triggerHaptic(settings);
                  Navigator.pop(dialogContext);
                  String numberedName = finalFileName;
                  final ext = p.extension(finalFileName);
                  final base = p.basenameWithoutExtension(finalFileName);
                  var counter = 1;
                  while (true) {
                    final candidate = '${base}_$counter$ext';
                    final exists = provider.tasks.any(
                      (t) =>
                          t.fileName.toLowerCase() == candidate.toLowerCase(),
                    );
                    if (!exists) {
                      numberedName = candidate;
                      break;
                    }
                    counter++;
                  }
                  try {
                    await provider.addDownload(
                      name: numberedName,
                      url: singleUrl,
                      size: finalSize,
                      category:
                          _selectedCategory == 'Auto' ? '' : _selectedCategory,
                      savePath: _pathController.text.trim(),
                      threadCount: _selectedThreads,
                      scheduledAt: _isScheduled ? _scheduledDateTime : null,
                      torrentFiles:
                          _torrentFiles.isNotEmpty ? _torrentFiles : null,
                      downloadPageUrl: widget.downloadPageUrl ??
                          _referrerController.text.trim(),
                      youtubeQualityPreset: _resolvedYoutubeQualityPreset,
                      torrentId: _resolvedTorrentId,
                      mergedAudioUrl: _resolvedAudioUrl,
                      audioSize: _resolvedAudioSize ?? 0,
                      thumbnailUrl: _resolvedThumbnailUrl,
                    );
                    if (!mounted) return;
                    if (!context.mounted) return;
                    AddDownloadDialog.recordAddedUrl(singleUrl);
                    if (mounted) setState(() => _isSubmitting = false);
                    Navigator.pop(context);
                  } catch (e) {
                    if (!mounted) return;
                    if (!context.mounted) return;
                    ThemedSnackbar.show(
                      context,
                      message: e.toString(),
                      color: redClr,
                      icon: Icons.error_outline,
                      isDarkMode: isDark,
                    );
                    if (mounted) setState(() => _isSubmitting = false);
                  }
                },
                child: Text(
                  isRtl ? 'إضافة كملف مرقم' : 'ADD NUMBERED',
                  style: TextStyle(
                    color:
                        isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  triggerHaptic(settings);
                  if (mounted) setState(() => _isSubmitting = false);
                  Navigator.pop(dialogContext);
                },
                child: Text(
                  L10n.of(context, 'cancel_btn'),
                  style: TextStyle(
                    color:
                        isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                  ),
                ),
              ),
            ],
          );
        },
      );
    } else {
      await provider.addDownload(
        name: finalFileName,
        url: singleUrl,
        size: finalSize,
        category: _selectedCategory == 'Auto' ? '' : _selectedCategory,
        savePath: _pathController.text.trim(),
        threadCount: _selectedThreads,
        scheduledAt: _isScheduled ? _scheduledDateTime : null,
        torrentFiles: _torrentFiles.isNotEmpty ? _torrentFiles : null,
        downloadPageUrl:
            widget.downloadPageUrl ?? _referrerController.text.trim(),
        youtubeQualityPreset: _resolvedYoutubeQualityPreset,
        torrentId: _resolvedTorrentId,
        mergedAudioUrl: _resolvedAudioUrl,
        audioSize: _resolvedAudioSize ?? 0,
        thumbnailUrl: _resolvedThumbnailUrl,
      );
      if (!mounted) return;
      if (!context.mounted) return;
      if (provider.lastError != null) {
        ThemedSnackbar.show(
          context,
          message: provider.lastError!,
          color: redClr,
          icon: Icons.error_outline,
          isDarkMode: isDark,
        );
        return;
      }
      AddDownloadDialog.recordAddedUrl(singleUrl);
      ThemedSnackbar.show(
        context,
        message: isRtl ? 'تم إنشاء الاتصال' : 'TRANSMISSION ESTABLISHED',
        color: blueClr,
        icon: Icons.rocket_launch_outlined,
        isDarkMode: isDark,
      );
      if (mounted) setState(() => _isSubmitting = false);
      Navigator.pop(context);
    }
    if (mounted) setState(() => _isSubmitting = false);
  }

  bool get _urlValid {
    final lines = _urlController.text
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return lines.isNotEmpty && lines.every((l) => isValidTransmissionUrl(l));
  }

  void _stepThread(int delta) {
    final idx = _threadsList.indexOf(_selectedThreads);
    final next = (idx + delta).clamp(0, _threadsList.length - 1);
    setState(() => _selectedThreads = _threadsList[next]);
    triggerHaptic(context.read<SettingsProvider>());
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isBatterySaver = settings.batterySaverMode;
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;

    final borderClr = isDark ? AppTheme.border : AppTheme.lightBorder;
    final classicUi = settings.classicUi;
    final panelBg = classicUi
        ? (isDark ? const Color(0xFF0F0F16) : const Color(0xFFF1F5F9))
        : (isDark
            ? AppTheme.surface.withValues(alpha: 0.4)
            : AppTheme.lightSurface.withValues(alpha: 0.4));
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: DmxCardShell(
          accent: blueClr,
          radius: 20,
          showRail: false,
          child: Stack(
            children: [
              AbsorbPointer(
                absorbing:
                    (_isResolvingLink && !_isTorrentOrMagnet) || _isSubmitting,
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: blueClr.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: blueClr.withValues(alpha: 0.3),
                                  ),
                                ),
                                child: Icon(
                                  Icons.download_rounded,
                                  color: blueClr,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      L10n.of(context, 'download_file_title'),
                                      style: TextStyle(
                                        color: textClr,
                                        fontFamily: 'Space Grotesk',
                                        fontSize: 18.0,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      isRtl
                                          ? 'إشارة تنزيل جديدة'
                                          : 'NEW TRANSMISSION SIGNAL',
                                      style: TextStyle(
                                        color: mutedClr,
                                        fontSize: 10.0,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              _HeaderAction(
                                icon: Icons.content_paste_rounded,
                                tooltip: isRtl ? 'لصق' : 'Paste',
                                color: secClr,
                                onTap: _pasteFromClipboard,
                              ),
                              const SizedBox(width: 6),
                              _HeaderAction(
                                icon: Icons.language_rounded,
                                tooltip: isRtl
                                    ? 'فتح في المتصفح'
                                    : 'Open in browser',
                                color: secClr,
                                onTap: () async {
                                  final messenger = ScaffoldMessenger.of(
                                    context,
                                  );
                                  final url = _urlController.text.trim();
                                  if (url.isEmpty) {
                                    messenger.removeCurrentSnackBar();
                                    messenger.showSnackBar(
                                      SnackBar(
                                        backgroundColor: Colors.transparent,
                                        elevation: 0,
                                        behavior: SnackBarBehavior.floating,
                                        duration: const Duration(
                                          milliseconds: 2600,
                                        ),
                                        margin: const EdgeInsets.fromLTRB(
                                          12,
                                          0,
                                          12,
                                          14,
                                        ),
                                        padding: EdgeInsets.zero,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                        content: Text(
                                          isRtl
                                              ? 'لا يوجد رابط لفتحه'
                                              : 'No URL to open',
                                        ),
                                      ),
                                    );
                                    return;
                                  }
                                  final uri = Uri.tryParse(url);
                                  if (uri != null && await canLaunchUrl(uri)) {
                                    await launchUrl(
                                      uri,
                                      mode: LaunchMode.externalApplication,
                                    );
                                  } else if (mounted) {
                                    messenger.removeCurrentSnackBar();
                                    messenger.showSnackBar(
                                      SnackBar(
                                        backgroundColor: Colors.transparent,
                                        elevation: 0,
                                        behavior: SnackBarBehavior.floating,
                                        duration: const Duration(
                                          milliseconds: 2600,
                                        ),
                                        margin: const EdgeInsets.fromLTRB(
                                          12,
                                          0,
                                          12,
                                          14,
                                        ),
                                        padding: EdgeInsets.zero,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                        content: Text(
                                          isRtl
                                              ? 'لا يمكن فتح الرابط'
                                              : 'Cannot open URL',
                                        ),
                                      ),
                                    );
                                  }
                                },
                              ),
                              const SizedBox(width: 6),
                              _HeaderAction(
                                icon: Icons.close_rounded,
                                tooltip: isRtl ? 'إغلاق' : 'Close',
                                color: secClr,
                                onTap: () => Navigator.pop(context),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          _SectionLabel(
                            text: L10n.of(context, 'link_label'),
                            color: mutedClr,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                GestureDetector(
                                  onTap: _pickTorrentFile,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: violetClr.withValues(alpha: 0.10),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: violetClr.withValues(alpha: 0.3),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.folder_open_rounded,
                                          size: 12,
                                          color: violetClr,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          isRtl ? 'ملف تورنت' : '.TORRENT',
                                          style: TextStyle(
                                            color: violetClr,
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 0.8,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          _CornerFrame(
                            color: _urlController.text.trim().isEmpty
                                ? borderClr
                                : (_urlValid
                                    ? greenClr
                                    : (isDark
                                        ? AppTheme.neonRed
                                        : AppTheme.lightNeonRed)),
                            child: AnimatedBuilder(
                              animation: Listenable.merge([
                                _urlController,
                                _urlFocus,
                              ]),
                              builder: (context, child) {
                                return Container(
                                  decoration: BoxDecoration(
                                    color: panelBg,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Stack(
                                    children: [
                                      if (_urlFocus.hasFocus && isDark)
                                        Positioned.fill(
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            child: AnimatedBuilder(
                                              animation: _scanController,
                                              builder: (context, child) =>
                                                  LayoutBuilder(
                                                builder: (context, c) {
                                                  final x = (c.maxWidth + 60) *
                                                          _scanController
                                                              .value -
                                                      60;
                                                  return Stack(
                                                    children: [
                                                      Positioned(
                                                        left: x,
                                                        top: 0,
                                                        bottom: 0,
                                                        child: Container(
                                                          width: 40,
                                                          decoration:
                                                              BoxDecoration(
                                                            gradient:
                                                                LinearGradient(
                                                              colors: [
                                                                blueClr
                                                                    .withValues(
                                                                  alpha: 0,
                                                                ),
                                                                blueClr
                                                                    .withValues(
                                                                  alpha: 0.06,
                                                                ),
                                                                blueClr
                                                                    .withValues(
                                                                  alpha: 0,
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  );
                                                },
                                              ),
                                            ),
                                          ),
                                        ),
                                      TextFormField(
                                        controller: _urlController,
                                        focusNode: _urlFocus,
                                        maxLines: 3,
                                        minLines: 1,
                                        maxLength: 2048,
                                        style: TextStyle(
                                          color: textClr,
                                          fontSize: 12,
                                          fontFamily: 'monospace',
                                          height: 1.4,
                                        ),
                                        validator: (val) {
                                          if (val == null ||
                                              val.trim().isEmpty) {
                                            return L10n.of(
                                              context,
                                              'url_empty_error',
                                            );
                                          }
                                          final lines = val
                                              .split(RegExp(r'[\r\n]+'))
                                              .map((l) => l.trim())
                                              .where((l) => l.isNotEmpty)
                                              .toList();
                                          if (lines.isEmpty) {
                                            return L10n.of(
                                              context,
                                              'url_empty_error',
                                            );
                                          }
                                          for (final line in lines) {
                                            if (!isValidTransmissionUrl(line)) {
                                              return L10n.of(
                                                context,
                                                'url_invalid_error',
                                              );
                                            }
                                          }
                                          return null;
                                        },
                                        decoration: InputDecoration(
                                          hintText:
                                              'https:// …  |  magnet:?xt= …',
                                          hintStyle: TextStyle(
                                            color: mutedClr.withValues(
                                              alpha: 0.6,
                                            ),
                                            fontSize: 12,
                                            fontFamily: 'monospace',
                                          ),
                                          filled: true,
                                          fillColor: panelBg,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 12,
                                          ),
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            borderSide: BorderSide.none,
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            borderSide: BorderSide.none,
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            borderSide: BorderSide(
                                              color: blueClr.withValues(
                                                alpha: 0.5,
                                              ),
                                              width: 1.2,
                                            ),
                                          ),
                                          errorBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            borderSide: BorderSide(
                                              color: (isDark
                                                      ? AppTheme.neonRed
                                                      : AppTheme.lightNeonRed)
                                                  .withValues(alpha: 0.6),
                                              width: 1.0,
                                            ),
                                          ),
                                          focusedErrorBorder:
                                              OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            borderSide: BorderSide(
                                              color: (isDark
                                                      ? AppTheme.neonRed
                                                      : AppTheme.lightNeonRed)
                                                  .withValues(alpha: 0.8),
                                              width: 1.2,
                                            ),
                                          ),
                                          errorStyle: const TextStyle(
                                            fontSize: 10,
                                            height: 0.8,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                          if (_urlAnalysis != null &&
                              _urlController.text.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6, bottom: 2),
                              child: _IntelligenceChip(
                                  analysis: _urlAnalysis!, isDark: isDark),
                            ),
                          AnimatedBuilder(
                            animation: _urlController,
                            builder: (context, child) {
                              if (_urlController.text.trim().isEmpty) {
                                return const SizedBox.shrink();
                              }
                              final valid = _urlValid;
                              final lineCount = _urlController.text
                                  .split(RegExp(r'[\r\n]+'))
                                  .where((l) => l.trim().isNotEmpty)
                                  .length;
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Row(
                                  children: [
                                    Icon(
                                      valid
                                          ? Icons.check_circle_rounded
                                          : Icons.cancel_rounded,
                                      size: 13,
                                      color: valid
                                          ? greenClr
                                          : (isDark
                                              ? AppTheme.neonRed
                                              : AppTheme.lightNeonRed),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      valid
                                          ? (lineCount > 1
                                              ? (isRtl
                                                  ? '$lineCount روابط صالحة'
                                                  : '$lineCount VALID SIGNALS')
                                              : (isRtl
                                                  ? 'إشارة صالحة'
                                                  : 'SIGNAL VALID'))
                                          : (isRtl
                                              ? 'إشارة غير صالحة'
                                              : 'INVALID SIGNAL'),
                                      style: TextStyle(
                                        color: valid
                                            ? greenClr
                                            : (isDark
                                                ? AppTheme.neonRed
                                                : AppTheme.lightNeonRed),
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 14),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 3,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _SectionLabel(
                                      text: L10n.of(context, 'file_name_label'),
                                      color: mutedClr,
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: TextFormField(
                                            controller: _nameController,
                                            style: TextStyle(
                                              color: textClr,
                                              fontSize: 12,
                                            ),
                                            onChanged: (v) => _userEditedName =
                                                v.trim().isNotEmpty,
                                            validator: (val) {
                                              if (val == null ||
                                                  val.trim().isEmpty) {
                                                return L10n.of(
                                                  context,
                                                  'filename_empty_error',
                                                );
                                              }
                                              return null;
                                            },
                                            decoration: InputDecoration(
                                              hintText: 'filename',
                                              hintStyle: TextStyle(
                                                color: mutedClr.withValues(
                                                  alpha: 0.6,
                                                ),
                                                fontSize: 11,
                                              ),
                                              filled: true,
                                              fillColor: panelBg,
                                              errorStyle: const TextStyle(
                                                fontSize: 10,
                                                height: 0.8,
                                              ),
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 12,
                                                vertical: 11,
                                              ),
                                              border: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                borderSide: BorderSide(
                                                  color: borderClr.withValues(
                                                    alpha: 0.5,
                                                  ),
                                                  width: 0.8,
                                                ),
                                              ),
                                              enabledBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                borderSide: BorderSide(
                                                  color: borderClr.withValues(
                                                    alpha: 0.5,
                                                  ),
                                                  width: 0.8,
                                                ),
                                              ),
                                              focusedBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                borderSide: BorderSide(
                                                  color: blueClr.withValues(
                                                    alpha: 0.5,
                                                  ),
                                                  width: 1.2,
                                                ),
                                              ),
                                              errorBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                borderSide: BorderSide(
                                                  color: (isDark
                                                          ? AppTheme.neonRed
                                                          : AppTheme
                                                              .lightNeonRed)
                                                      .withValues(
                                                    alpha: 0.6,
                                                  ),
                                                  width: 1.0,
                                                ),
                                              ),
                                              focusedErrorBorder:
                                                  OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(
                                                  12,
                                                ),
                                                borderSide: BorderSide(
                                                  color: (isDark
                                                          ? AppTheme.neonRed
                                                          : AppTheme
                                                              .lightNeonRed)
                                                      .withValues(
                                                    alpha: 0.8,
                                                  ),
                                                  width: 1.2,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                          ),
                                          child: Text(
                                            '.',
                                            style: TextStyle(
                                              color: secClr,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                          ),
                                        ),
                                        SizedBox(
                                          width: 62,
                                          child: TextFormField(
                                            controller: _extController,
                                            style: TextStyle(
                                              color: textClr,
                                              fontSize: 12,
                                              fontFamily: 'monospace',
                                            ),
                                            decoration: InputDecoration(
                                              hintText: 'ext',
                                              hintStyle: TextStyle(
                                                color: mutedClr.withValues(
                                                  alpha: 0.6,
                                                ),
                                                fontSize: 11,
                                                fontFamily: 'monospace',
                                              ),
                                              filled: true,
                                              fillColor: panelBg,
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 11,
                                              ),
                                              border: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                borderSide: BorderSide(
                                                  color: borderClr.withValues(
                                                    alpha: 0.5,
                                                  ),
                                                  width: 0.8,
                                                ),
                                              ),
                                              enabledBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                borderSide: BorderSide(
                                                  color: borderClr.withValues(
                                                    alpha: 0.5,
                                                  ),
                                                  width: 0.8,
                                                ),
                                              ),
                                              focusedBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                borderSide: BorderSide(
                                                  color: blueClr.withValues(
                                                    alpha: 0.5,
                                                  ),
                                                  width: 1.2,
                                                ),
                                              ),
                                              errorBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                borderSide: BorderSide(
                                                  color: (isDark
                                                          ? AppTheme.neonRed
                                                          : AppTheme
                                                              .lightNeonRed)
                                                      .withValues(
                                                    alpha: 0.6,
                                                  ),
                                                  width: 1.0,
                                                ),
                                              ),
                                              focusedErrorBorder:
                                                  OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(
                                                  12,
                                                ),
                                                borderSide: BorderSide(
                                                  color: (isDark
                                                          ? AppTheme.neonRed
                                                          : AppTheme
                                                              .lightNeonRed)
                                                      .withValues(
                                                    alpha: 0.8,
                                                  ),
                                                  width: 1.2,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 2,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _SectionLabel(
                                      text: L10n.of(context, 'category_label'),
                                      color: mutedClr,
                                    ),
                                    const SizedBox(height: 8),
                                    Container(
                                      decoration: BoxDecoration(
                                        color: panelBg,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: borderClr.withValues(
                                            alpha: 0.5,
                                          ),
                                          width: 0.8,
                                        ),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: DropdownButtonHideUnderline(
                                        child: DropdownButton<String>(
                                          dropdownColor: isDark
                                              ? AppTheme.surface
                                              : AppTheme.lightSurface,
                                          value: _selectedCategory,
                                          isExpanded: true,
                                          icon: Icon(
                                            Icons.arrow_drop_down,
                                            color: secClr,
                                            size: 18,
                                          ),
                                          style: TextStyle(
                                            color: textClr,
                                            fontSize: 12,
                                          ),
                                          items: _categories.map((cat) {
                                            return DropdownMenuItem<String>(
                                              value: cat,
                                              child: Text(
                                                L10n.translateCategory(
                                                  context,
                                                  cat,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            );
                                          }).toList(),
                                          onChanged: (val) {
                                            if (val != null) {
                                              runHaptic(settings);
                                              setState(
                                                () => _selectedCategory = val,
                                              );
                                            }
                                          },
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              if (!_isTorrentOrMagnet) ...[
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          _SectionLabel(
                                            text: L10n.of(
                                                context, 'threads_label'),
                                            color: mutedClr,
                                          ),
                                          const SizedBox.shrink(),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Container(
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: panelBg,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(color: borderClr),
                                        ),
                                        child: Row(
                                          children: [
                                            _StepBtn(
                                              icon: Icons.remove_rounded,
                                              onTap: isBatterySaver
                                                  ? null
                                                  : () => _stepThread(-1),
                                              color: secClr,
                                            ),
                                            Expanded(
                                              child: Center(
                                                child: Text(
                                                  '$_selectedThreads',
                                                  style: TextStyle(
                                                    color: blueClr,
                                                    fontFamily: 'Space Grotesk',
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 15,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            _StepBtn(
                                              icon: Icons.add_rounded,
                                              onTap: isBatterySaver
                                                  ? null
                                                  : () => _stepThread(1),
                                              color: secClr,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                              ],
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _SectionLabel(
                                      text: isRtl ? 'خيارات' : 'OPTIONS',
                                      color: mutedClr,
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        _ToggleChip(
                                          icon: Icons.wifi_rounded,
                                          label: isRtl ? 'واي فاي' : 'WI-FI',
                                          active: _wifiOnly,
                                          color: blueClr,
                                          isDark: isDark,
                                          onTap: () => setState(
                                            () => _wifiOnly = !_wifiOnly,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        _ToggleChip(
                                          icon: Icons.refresh_rounded,
                                          label: isRtl ? 'إعادة' : 'RETRY',
                                          active: _retry,
                                          color: greenClr,
                                          isDark: isDark,
                                          onTap: () =>
                                              setState(() => _retry = !_retry),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          GestureDetector(
                            onTap: () {
                              triggerHaptic(settings);
                              setState(() => _showAdvanced = !_showAdvanced);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: panelBg,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: borderClr),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.tune_rounded,
                                    size: 15,
                                    color: secClr,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      isRtl
                                          ? 'خيارات متقدمة'
                                          : 'ADVANCED OPTIONS',
                                      style: TextStyle(
                                        color: secClr,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1,
                                      ),
                                    ),
                                  ),
                                  AnimatedRotation(
                                    turns: _showAdvanced ? 0.5 : 0,
                                    duration: const Duration(milliseconds: 200),
                                    child: Icon(
                                      Icons.keyboard_arrow_up_rounded,
                                      size: 16,
                                      color: secClr,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          AnimatedCrossFade(
                            firstChild: const SizedBox(width: double.infinity),
                            secondChild: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 10),
                                TextFormField(
                                  controller: _referrerController,
                                  style: TextStyle(
                                    color: textClr,
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                  ),
                                  decoration: InputDecoration(
                                    hintText: isRtl
                                        ? 'رابط صفحة التنزيل (اختياري)'
                                        : 'Download / referrer page link (optional)',
                                    hintStyle: TextStyle(
                                      color: mutedClr.withValues(alpha: 0.6),
                                      fontSize: 11,
                                    ),
                                    filled: true,
                                    fillColor: panelBg,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 11,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(
                                        color: borderClr.withValues(alpha: 0.5),
                                        width: 0.8,
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(
                                        color: borderClr.withValues(alpha: 0.5),
                                        width: 0.8,
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(
                                        color: blueClr.withValues(alpha: 0.5),
                                        width: 1.2,
                                      ),
                                    ),
                                    errorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(
                                        color: (isDark
                                                ? AppTheme.neonRed
                                                : AppTheme.lightNeonRed)
                                            .withValues(alpha: 0.6),
                                        width: 1.0,
                                      ),
                                    ),
                                    focusedErrorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(
                                        color: (isDark
                                                ? AppTheme.neonRed
                                                : AppTheme.lightNeonRed)
                                            .withValues(alpha: 0.8),
                                        width: 1.2,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                _SectionLabel(
                                  text: L10n.of(context, 'save_path_label'),
                                  color: mutedClr,
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextFormField(
                                        controller: _pathController,
                                        style: TextStyle(
                                          color: textClr,
                                          fontSize: 11,
                                          fontFamily: 'monospace',
                                        ),
                                        validator: (val) {
                                          if (val == null ||
                                              val.trim().isEmpty) {
                                            return 'Save path cannot be empty';
                                          }
                                          return null;
                                        },
                                        decoration: InputDecoration(
                                          filled: true,
                                          fillColor: panelBg,
                                          errorStyle: const TextStyle(
                                            fontSize: 10,
                                            height: 0.8,
                                          ),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 11,
                                          ),
                                          border: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            borderSide: BorderSide(
                                              color: borderClr.withValues(
                                                  alpha: 0.5),
                                              width: 0.8,
                                            ),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            borderSide: BorderSide(
                                              color: borderClr.withValues(
                                                  alpha: 0.5),
                                              width: 0.8,
                                            ),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            borderSide: BorderSide(
                                              color: blueClr.withValues(
                                                  alpha: 0.5),
                                              width: 1.2,
                                            ),
                                          ),
                                          errorBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            borderSide: BorderSide(
                                              color: (isDark
                                                      ? AppTheme.neonRed
                                                      : AppTheme.lightNeonRed)
                                                  .withValues(alpha: 0.6),
                                              width: 1.0,
                                            ),
                                          ),
                                          focusedErrorBorder:
                                              OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            borderSide: BorderSide(
                                              color: (isDark
                                                      ? AppTheme.neonRed
                                                      : AppTheme.lightNeonRed)
                                                  .withValues(alpha: 0.8),
                                              width: 1.2,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _SquareButton(
                                      icon: Icons.folder_open_rounded,
                                      color: blueClr,
                                      onTap: () async {
                                        runHaptic(settings);
                                        try {
                                          final result = await FilePicker
                                                  .getDirectoryPath()
                                              .timeout(
                                            const Duration(seconds: 30),
                                          );
                                          if (result != null) {
                                            setState(
                                              () =>
                                                  _pathController.text = result,
                                            );
                                          }
                                        } on TimeoutException {
                                          if (context.mounted) {
                                            ThemedSnackbar.show(
                                              context,
                                              message: L10n.isRtl(context)
                                                  ? 'انتهت مهلة تحديد المجلد'
                                                  : 'File picker timed out',
                                              color: AppTheme.neonRed,
                                              icon: Icons.error_outline,
                                              isDarkMode: settings.isDarkMode,
                                            );
                                          }
                                        }
                                      },
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                _ToggleRow(
                                  icon: Icons.schedule_rounded,
                                  label: isRtl ? 'جدولة' : 'Schedule',
                                  value: _isScheduled,
                                  color: violetClr,
                                  isDark: isDark,
                                  onChanged: (v) {
                                    setState(() {
                                      _isScheduled = v;
                                      if (_isScheduled &&
                                          _scheduledDateTime == null) {
                                        _scheduledDateTime = DateTime.now().add(
                                          const Duration(hours: 1),
                                        );
                                      }
                                    });
                                  },
                                ),
                                if (_isScheduled) ...[
                                  const SizedBox(height: 8),
                                  GestureDetector(
                                    onTap: () async {
                                      final now = DateTime.now();
                                      final date = await showDatePicker(
                                        context: context,
                                        initialDate: _scheduledDateTime ??
                                            now.add(const Duration(hours: 1)),
                                        firstDate: now,
                                        lastDate: now.add(
                                          const Duration(days: 365),
                                        ),
                                      );
                                      if (date != null && mounted) {
                                        if (!context.mounted) return;
                                        final time = await showTimePicker(
                                          context: context,
                                          initialTime: TimeOfDay.fromDateTime(
                                            _scheduledDateTime ??
                                                now.add(
                                                  const Duration(hours: 1),
                                                ),
                                          ),
                                        );
                                        if (time != null && mounted) {
                                          setState(() {
                                            _scheduledDateTime = DateTime(
                                              date.year,
                                              date.month,
                                              date.day,
                                              time.hour,
                                              time.minute,
                                            );
                                          });
                                        }
                                      }
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      decoration: BoxDecoration(
                                        color: violetClr.withValues(
                                          alpha: 0.08,
                                        ),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: violetClr.withValues(
                                            alpha: 0.4,
                                          ),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.schedule_rounded,
                                            size: 15,
                                            color: violetClr,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              _scheduledDateTime != null
                                                  ? '${_scheduledDateTime!.day}/${_scheduledDateTime!.month}/${_scheduledDateTime!.year}  ${_scheduledDateTime!.hour.toString().padLeft(2, '0')}:${_scheduledDateTime!.minute.toString().padLeft(2, '0')}'
                                                  : (isRtl
                                                      ? 'اختر الوقت'
                                                      : 'Tap to set date & time'),
                                              style: TextStyle(
                                                color: textClr,
                                                fontSize: 12,
                                                fontFamily: 'monospace',
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            crossFadeState: _showAdvanced
                                ? CrossFadeState.showSecond
                                : CrossFadeState.showFirst,
                            duration: const Duration(milliseconds: 220),
                          ),
                          if (_torrentFiles.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            _TorrentFilesPanel(
                              files: _torrentFiles,
                              isDark: isDark,
                              panelBg: panelBg,
                              borderClr: borderClr,
                              onToggle: (i, v) {
                                _torrentFiles[i]['selected'] = v;
                                _updateSelectedTorrentSize();
                              },
                              onSelectAll: (v) {
                                for (final f in _torrentFiles) {
                                  f['selected'] = v;
                                }
                                _updateSelectedTorrentSize();
                              },
                            ),
                          ],
                          const SizedBox(height: 20),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: Text(
                                  L10n.of(context, 'cancel_btn'),
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (_isResolvingLink)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 15,
                                        height: 15,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: blueClr,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        isRtl ? 'جارٍ الاتصال…' : 'ACQUIRING…',
                                        style: TextStyle(
                                          color: blueClr,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 1,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              else
                                TextButton(
                                  onPressed: _resolveLinkMetadata,
                                  child: Text(
                                    L10n.of(context, 'connect_btn'),
                                    style: TextStyle(
                                      color: blueClr,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.0,
                                    ),
                                  ),
                                ),
                              const SizedBox(width: 4),
                              NeonGlowButton(
                                onPressed: ((_isResolvingLink &&
                                            !_isTorrentOrMagnet) ||
                                        _isSubmitting)
                                    ? null
                                    : () {
                                        if (_formKey.currentState!.validate()) {
                                          _handleDuplicateOrSubmit();
                                        }
                                      },
                                text: (_isResolvingLink && !_isTorrentOrMagnet)
                                    ? (L10n.isRtl(context)
                                        ? 'إنتظار الاتصال...'
                                        : 'Connecting...')
                                    : _isSubmitting
                                        ? (L10n.isRtl(context)
                                            ? 'جاري الإضافة...'
                                            : 'Adding...')
                                        : L10n.of(context, 'add_btn'),
                                icon: Icons.add_circle_outline,
                                isLoading:
                                    (_isResolvingLink && !_isTorrentOrMagnet) ||
                                        _isSubmitting,
                                color: greenClr,
                                glowColor: greenClr,
                                isExpanded: false,
                                isFilled: true,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
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

class _SectionLabel extends StatelessWidget {
  final String text;
  final Color color;
  final Widget? trailing;
  const _SectionLabel({required this.text, required this.color, this.trailing});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 12.0,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _CornerFrame extends StatelessWidget {
  final Widget child;
  final Color color;
  const _CornerFrame({required this.child, required this.color});
  @override
  Widget build(BuildContext context) {
    const len = 12.0;
    Widget bracket(bool top, bool left) => CustomPaint(
          size: const Size(len, len),
          painter: _BracketPainter(color: color, top: top, left: left),
        );
    return Stack(
      children: [
        Padding(padding: const EdgeInsets.all(5), child: child),
        Positioned(top: 0, left: 0, child: bracket(true, true)),
        Positioned(top: 0, right: 0, child: bracket(true, false)),
        Positioned(bottom: 0, left: 0, child: bracket(false, true)),
        Positioned(bottom: 0, right: 0, child: bracket(false, false)),
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
      ..strokeWidth = 1.6
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
  bool shouldRepaint(covariant _BracketPainter oldDelegate) {
    return color != oldDelegate.color ||
        top != oldDelegate.top ||
        left != oldDelegate.left;
  }
}

class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;
  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: Material(
        color: Colors.transparent,
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              child: Icon(icon, size: 18, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

class _IntelligenceChip extends StatelessWidget {
  final UrlAnalysisResult analysis;
  final bool isDark;
  const _IntelligenceChip({required this.analysis, required this.isDark});
  @override
  Widget build(BuildContext context) {
    final accent = (analysis.siteType == SiteType.videoStreaming ||
            analysis.contentHint == ContentHint.videoFile)
        ? AppTheme.neonBlue
        : (analysis.siteType == SiteType.magnetSource
            ? AppTheme.neonViolet
            : AppTheme.neonGreen);
    final icon = (analysis.siteType == SiteType.videoStreaming ||
            analysis.contentHint == ContentHint.videoFile)
        ? Icons.play_circle_outline
        : (analysis.siteType == SiteType.magnetSource
            ? Icons.link_rounded
            : Icons.info_outline);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: accent),
          const SizedBox(width: 6),
          Text(
            '${analysis.profile?.displayName ?? analysis.siteType.name.toUpperCase()} • ${analysis.contentHint.name.replaceAll(RegExp(r"(?=[A-Z])"), " ").toUpperCase()}',
            style: TextStyle(
              color: accent,
              fontSize: 9,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          if (analysis.detectedQuality != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                analysis.detectedQuality!,
                style: const TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w900,
                    color: Colors.white),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SquareButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _SquareButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }
}

class _StepBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color color;
  const _StepBtn({
    required this.icon,
    required this.onTap,
    required this.color,
  });
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          child: Icon(icon,
              size: 17,
              color: onTap == null ? color.withValues(alpha: 0.3) : color),
        ),
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color color;
  final bool isDark;
  final VoidCallback onTap;
  const _ToggleChip({
    required this.icon,
    required this.label,
    required this.active,
    required this.color,
    required this.isDark,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: active
                ? color.withValues(alpha: 0.45)
                : (isDark ? AppTheme.border : AppTheme.lightBorder),
            width: active ? 1 : 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: active
                  ? color
                  : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: active
                    ? color
                    : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted),
                fontSize: 9,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final Color color;
  final bool isDark;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    required this.isDark,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          icon,
          size: 15,
          color: value
              ? color
              : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
              fontSize: 12,
            ),
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: color,
          activeTrackColor: color.withValues(alpha: 0.25),
        ),
      ],
    );
  }
}

class _TorrentFilesPanel extends StatelessWidget {
  final List<Map<String, dynamic>> files;
  final bool isDark;
  final Color panelBg;
  final Color borderClr;
  final void Function(int, bool) onToggle;
  final void Function(bool) onSelectAll;
  const _TorrentFilesPanel({
    required this.files,
    required this.isDark,
    required this.panelBg,
    required this.borderClr,
    required this.onToggle,
    required this.onSelectAll,
  });
  @override
  Widget build(BuildContext context) {
    final violet = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final selectedCount = files.where((f) => f['selected'] == true).length;
    return Container(
      decoration: BoxDecoration(
        color: panelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: violet.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
            child: Row(
              children: [
                Icon(Icons.folder_zip_rounded, size: 15, color: violet),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${L10n.isRtl(context) ? "ملفات التورنت" : "TORRENT FILES"} ($selectedCount/${files.length})',
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textPrimary
                          : AppTheme.lightTextPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.6,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => onSelectAll(true),
                  child: Text(
                    L10n.isRtl(context) ? 'الكل' : 'ALL',
                    style: TextStyle(
                      fontSize: 10,
                      color: violet,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => onSelectAll(false),
                  child: Text(
                    L10n.isRtl(context) ? 'إلغاء' : 'NONE',
                    style: TextStyle(
                      fontSize: 10,
                      color:
                          isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            constraints: const BoxConstraints(maxHeight: 180),
            margin: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: (isDark ? Colors.black : Colors.white).withValues(
                alpha: 0.15,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.separated(
              physics: const ClampingScrollPhysics(),
              itemCount: files.length,
              separatorBuilder: (context, index) =>
                  Divider(color: borderClr.withValues(alpha: 0.3), height: 1),
              itemBuilder: (ctx, idx) {
                final file = files[idx];
                final isSelected = file['selected'] as bool? ?? true;
                final fileName = (file['name'] as String? ?? '').replaceAll(
                  '+',
                  ' ',
                );
                final length = (file['length'] as num?)?.toInt() ?? 0;
                return Material(
                  color: Colors.transparent,
                  child: CheckboxListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    activeColor: violet,
                    value: isSelected,
                    title: Text(
                      fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSelected
                            ? (isDark
                                ? AppTheme.textPrimary
                                : AppTheme.lightTextPrimary)
                            : (isDark
                                ? AppTheme.textSecondary
                                : AppTheme.lightTextSecondary),
                        fontSize: 12,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.normal,
                        decoration:
                            isSelected ? null : TextDecoration.lineThrough,
                      ),
                    ),
                    subtitle: Text(
                      formatBytes(length.toDouble()),
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.textMuted
                            : AppTheme.lightTextMuted,
                        fontSize: 10,
                        fontFamily: 'monospace',
                      ),
                    ),
                    onChanged: (val) => onToggle(idx, val ?? true),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
