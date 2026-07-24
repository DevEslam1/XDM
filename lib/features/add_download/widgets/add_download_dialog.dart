import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

import 'package:path/path.dart' as p;

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

import '../../downloads/provider/download_provider.dart';
import '../../downloads/models/download_task.dart';
import '../../settings/provider/settings_provider.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/neon_glow_button.dart';

import '../widgets/youtube_quality_sheet.dart';
import '../widgets/youtube_playlist_sheet.dart';

class AddDownloadDialog extends StatefulWidget {
  final String? prefilledUrl;
  final String? prefilledName;
  final String? downloadPageUrl;

  const AddDownloadDialog({
    super.key,
    this.prefilledUrl,
    this.prefilledName,
    this.downloadPageUrl,
  });

  @override
  State<AddDownloadDialog> createState() => _AddDownloadDialogState();
}

class _AddDownloadDialogState extends State<AddDownloadDialog>
    with HapticHelper {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _referrerController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _extController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  String _selectedCategory = 'Auto';
  int _selectedThreads = 5;

  // UI Checkboxes
  bool _wifiOnly = false;
  bool _retry = true;
  bool _useProxy = false;

  bool _isScheduled = false;
  DateTime? _scheduledDateTime;
  String? _resolvedYoutubeQualityPreset;
  String? _resolvedAudioUrl;
  int? _resolvedAudioSize;

  bool _isMetadataResolved = false;
  bool _isResolvingLink = false;
  String _resolvedFileName = '';
  int _resolvedFileSize = 0;
  int? _resolvedTorrentId;
  String _resolvedCategory = 'Auto';

  List<Map<String, dynamic>> _torrentFiles = [];
  String _lastCheckedUrl = '';
  Timer? _ytDebounceTimer;

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

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>();
    if (_threadsList.contains(settings.defaultThreadCount)) {
      _selectedThreads = settings.defaultThreadCount;
    }
    _wifiOnly = settings.wifiOnly;
    _useProxy = settings.enableProxy;

    _loadDefaultPath();
    _urlController.addListener(_onUrlChanged);

    if (widget.prefilledUrl != null) {
      _urlController.text = widget.prefilledUrl!;
      final url = widget.prefilledUrl!;
      if (YoutubeService.isYoutubeVideoUrl(url) ||
          YoutubeService.isPlaylistUrl(url)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _resolveLinkMetadata();
        });
      } else if (url.trim().toLowerCase().startsWith('magnet:')) {
        final parsed = parseMagnetUrl(url);
        final dnName = parsed['name'] ?? 'Torrent Download';
        _setNameAndExt(dnName);
        _resolvedFileName = dnName;
        _resolvedCategory = 'Archive';
        _selectedCategory = 'Archive';
        _isMetadataResolved = true;
      }
    }
    if (widget.prefilledName != null) {
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

    if (url.toLowerCase().startsWith('magnet:')) {
      final parsed = parseMagnetUrl(url);
      final dnName = parsed['name'] ?? 'Torrent Download';
      setState(() {
        if (_nameController.text.isEmpty ||
            _nameController.text == 'Torrent Download') {
          _setNameAndExt(dnName);
        }
        _resolvedFileName = _nameController.text.isNotEmpty
            ? '${_nameController.text}.${_extController.text}'
            : dnName;
        _resolvedCategory = 'Archive';
        _selectedCategory = 'Archive';
        _isMetadataResolved = true;
      });
    } else if (YoutubeService.isYoutubeVideoUrl(url) ||
        YoutubeService.isPlaylistUrl(url)) {
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
        });
      }
    }
  }

  Future<void> _loadDefaultPath() async {
    final settings = context.read<SettingsProvider>();
    final path = settings.customDownloadPath?.isNotEmpty == true
        ? settings.customDownloadPath!
        : await PermissionService().defaultDownloadDirectory();
    if (!mounted) return;
    if (_pathController.text.isEmpty) {
      _pathController.text = path;
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
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      if (!mounted) return;
      _urlController.text = data.text!;
      _urlController.selection = TextSelection.fromPosition(
        TextPosition(offset: _urlController.text.length),
      );
      final url = data.text!.trim();
      if (YoutubeService.isYoutubeVideoUrl(url) ||
          YoutubeService.isPlaylistUrl(url)) {
        _resolveLinkMetadata();
      }
    }
  }

  Future<void> _resolveLinkMetadata() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ThemedSnackbar.show(
        context,
        message: L10n.isRtl(context)
            ? 'أدخل الرابط أولاً'
            : 'Enter a URL first',
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
          return; // dismissed
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

    if (YoutubeService.isYoutubeVideoUrl(url)) {
      if (!mounted) return;
      final stream = await YoutubeQualitySheet.show(context, url);
      if (!mounted) return;
      if (stream == null) {
        return;
      }
      if (mounted) {
        final title = stream['title'] as String? ?? 'YouTube Video';
        final ext = stream['ext'] as String? ?? 'mp4';
        final streamUrl = stream['src'] as String;
        final streamSize = stream['size'] as int? ?? 0;
        final audioUrl = stream['audioSrc'] as String?;
        final audioSize = stream['audioSize'] as int?;
        final streamType = stream['type'] as String? ?? 'muxed';
        final qualityPreset = streamType == 'audio' ? 'audio_only' : stream['quality'] as String?;
        final category = streamType == 'audio' ? 'Audio' : 'Video';
        final fileName = '$title.$ext';

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
          message: L10n.isRtl(context)
              ? 'تم بدء التحميل'
              : 'Download started',
          color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          icon: Icons.check_circle_outline,
          isDarkMode: isDark,
        );
        Navigator.pop(context);
      }
      return;
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
      if (url.startsWith('file://')) {
        final filePath = Uri.parse(url).toFilePath();
        final file = File(filePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final meta = await compute(BencodeDecoder.parseTorrentBytes, bytes);
          if (!mounted) return;
          if (meta != null) {
            setState(() {
              _resolvedFileName = meta['name'] ?? '';
              _resolvedFileSize = meta['length'] ?? 0;
              _resolvedCategory = 'Archive';
              _torrentFiles = (meta['files'] as List? ?? [])
                  .map(
                    (f) => ({
                      'name': f['name'] as String? ?? '',
                      'length': f['length'] as int? ?? 0,
                      'selected': true,
                      'priority': 4,
                      'downloadedBytes': 0,
                      'speed': 0.0,
                    }),
                  )
                  .toList();
              _isMetadataResolved = true;
              _setNameAndExt(_resolvedFileName);
              _selectedCategory = 'Archive';
            });
            return;
          }
        }
      }

      final engine = DownloadEngine();
      final nameForReq = _nameController.text.trim().isNotEmpty
          ? '${_nameController.text}.${_extController.text}'
          : null;
      DownloadMetadata meta;
      try {
        meta = await engine.resolveMetadata(
          url: url,
          requestedFileName: nameForReq,
          customUserAgent: settings.customUserAgent,
          enableProxy: settings.enableProxy,
          proxyAddress: settings.proxyAddress,
          proxyHost: settings.proxyHost,
          proxyPort: settings.proxyPort,
          proxyUsername: settings.proxyUsername,
          proxyPassword: settings.proxyPassword,
          bypassSSL: settings.bypassSSL,
        );
      } finally {
        engine.close();
      }

      if (!mounted) return;
      setState(() {
        _resolvedFileName = meta.fileName;
        _resolvedFileSize = meta.fileSize;
        _resolvedTorrentId = meta.torrentId;
        _resolvedCategory = meta.category;
        _torrentFiles = meta.torrentFiles ?? [];
        _isMetadataResolved = true;
        _setNameAndExt(_resolvedFileName);
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
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final provider = context.read<DownloadProvider>();

    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    // Split URLs for multi-URL support
    final urls = _urlController.text
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    if (urls.length > 1) {
      // Multiple URLs: skip duplicate check, add each one
      var addedCount = 0;
      for (final singleUrl in urls) {
        if (!isValidTransmissionUrl(singleUrl)) continue;
        final enteredName = _nameController.text.trim();
        final enteredExt = _extController.text.trim();
        String fullName = enteredName;
        if (enteredExt.isNotEmpty && !enteredName.endsWith(enteredExt)) {
          fullName = '$enteredName.$enteredExt';
        }
        final suffix = addedCount + 1;
        final singleName = fullName.isNotEmpty
            ? '${safeFileName(fullName)}_$suffix'
            : fileNameFromUrl(singleUrl);
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
                widget.downloadPageUrl ??
                _referrerController.text.trim(),
            youtubeQualityPreset: _resolvedYoutubeQualityPreset,
            torrentId: _resolvedTorrentId,
            mergedAudioUrl: _resolvedAudioUrl,
            audioSize: _resolvedAudioSize ?? 0,
          );
          addedCount++;
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
      if (addedCount > 0) {
        ThemedSnackbar.show(
          context,
          message: isRtl
              ? 'تم إضافة $addedCount رابط'
              : '$addedCount URLs added',
          color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          icon: Icons.check_circle_outline,
          isDarkMode: isDark,
        );
        Navigator.pop(context);
      }
      return;
    }

    final enteredName = _nameController.text.trim();
    final enteredExt = _extController.text.trim();
    String fullEnteredName = enteredName;
    if (enteredExt.isNotEmpty && !enteredName.endsWith(enteredExt)) {
      fullEnteredName = '$enteredName.$enteredExt';
    }

    final singleUrl = urls.isNotEmpty ? urls.first : '';
    final finalFileName = fullEnteredName.isNotEmpty
        ? safeFileName(fullEnteredName)
        : fileNameFromUrl(singleUrl);
    final int finalSize = _isMetadataResolved ? _resolvedFileSize : 0;

    DownloadTask? duplicateTask;
    final trimmedUrl = singleUrl.trim();
    for (final task in provider.tasks) {
      final isSameUrl = task.url.trim().toLowerCase() == trimmedUrl.toLowerCase();
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
        builder: (context) {
          return AlertDialog(
            backgroundColor: isDark ? AppTheme.surface : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(
                color: isDark
                    ? AppTheme.glassBorder
                    : AppTheme.lightGlassBorder,
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
                  Navigator.pop(context);
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
                      color: isDark
                          ? AppTheme.neonGreen
                          : AppTheme.lightNeonGreen,
                      icon: Icons.check_circle_outline,
                      isDarkMode: isDark,
                    );
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
                    color: isDark
                        ? AppTheme.neonViolet
                        : AppTheme.lightNeonViolet,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () async {
                  triggerHaptic(settings);
                  Navigator.pop(context);
                  try {
                    await provider.startOverTask(
                      duplicateTask!.id,
                      singleUrl,
                    );
                    if (!mounted) return;
                    if (!context.mounted) return;
                    ThemedSnackbar.show(
                      context,
                      message: isRtl ? 'بدأ من جديد' : 'Started over',
                      color: isDark
                          ? AppTheme.neonGreen
                          : AppTheme.lightNeonGreen,
                      icon: Icons.refresh,
                      isDarkMode: isDark,
                    );
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
                  }
                },
                child: Text(
                  isRtl ? 'بدء من جديد' : 'START OVER',
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.neonViolet
                        : AppTheme.lightNeonViolet,
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
                    color: isDark
                        ? AppTheme.neonGreen
                        : AppTheme.lightNeonGreen,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () async {
                  triggerHaptic(settings);
                  Navigator.pop(context);
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
                      category: _selectedCategory == 'Auto'
                          ? ''
                          : _selectedCategory,
                      savePath: _pathController.text.trim(),
                      threadCount: _selectedThreads,
                      scheduledAt: _isScheduled ? _scheduledDateTime : null,
                      torrentFiles: _torrentFiles.isNotEmpty
                          ? _torrentFiles
                          : null,
                      downloadPageUrl:
                          widget.downloadPageUrl ??
                          _referrerController.text.trim(),
                      youtubeQualityPreset: _resolvedYoutubeQualityPreset,
                      torrentId: _resolvedTorrentId,
                      mergedAudioUrl: _resolvedAudioUrl,
                      audioSize: _resolvedAudioSize ?? 0,
                    );
                    if (!mounted) return;
                    if (!context.mounted) return;
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
                  }
                },
                child: Text(
                  isRtl ? 'إضافة كملف مرقم' : 'ADD NUMBERED',
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.neonGreen
                        : AppTheme.lightNeonGreen,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  triggerHaptic(settings);
                  Navigator.pop(context);
                },
                child: Text(
                  L10n.of(context, 'cancel_btn'),
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.textMuted
                        : AppTheme.lightTextMuted,
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
            widget.downloadPageUrl ??
            _referrerController.text.trim(),
        youtubeQualityPreset: _resolvedYoutubeQualityPreset,
        torrentId: _resolvedTorrentId,
        mergedAudioUrl: _resolvedAudioUrl,
        audioSize: _resolvedAudioSize ?? 0,
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
      ThemedSnackbar.show(
        context,
        message: isRtl ? 'تم إنشاء الاتصال' : 'TRANSMISSION ESTABLISHED',
        color: blueClr,
        icon: Icons.rocket_launch_outlined,
        isDarkMode: isDark,
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;

    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final orangeClr = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    final inputBgColor =
        (isDark ? const Color(0xFF0F0F16) : const Color(0xFFF1F5F9)).withValues(
          alpha: 0.7,
        );
    final inputBorderColor = isDark
        ? const Color(0x15FFFFFF)
        : const Color(0x0D000000);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: GlassCard(
        isDarkMode: isDark,
        borderRadius: 20,
        padding: EdgeInsets.zero,
        child: Stack(
          children: [
            AbsorbPointer(
              absorbing: _isResolvingLink,
              child: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 20.0,
                    right: 20.0,
                    top: 20.0,
                    bottom: 20.0 + MediaQuery.of(context).viewInsets.bottom,
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Header
                        Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: blueClr.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: blueClr.withValues(alpha: 0.25),
                                  width: 0.8,
                                ),
                              ),
                              child: Icon(
                                Icons.download_rounded,
                                color: blueClr,
                                size: 16,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              L10n.of(context, 'download_file_title'),
                              style: TextStyle(
                                color: textClr,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: Icon(Icons.paste, color: secClr, size: 20),
                              onPressed: _pasteFromClipboard,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                            const SizedBox(width: 16),
                            IconButton(
                              icon: Icon(Icons.language, color: secClr, size: 20),
                              onPressed: () {
                                final settings = context.read<SettingsProvider>();
                                final nextLang = settings.languageCode == 'en' ? 'ar' : 'en';
                                settings.setLanguageCode(nextLang);
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),

                        // Link labels
                        Row(
                          children: [
                            Text(
                              L10n.of(context, 'link_label'),
                              style: TextStyle(
                                color: secClr,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(Icons.copy, color: secClr, size: 14),
                            const SizedBox(width: 8),
                            Icon(Icons.share, color: secClr, size: 14),
                          ],
                        ),
                        const SizedBox(height: 8),

                        // Download link field
                        Stack(
                          alignment: Alignment.centerRight,
                          children: [
                            _buildTextField(
                              controller: _urlController,
                              hint: L10n.of(context, 'add_download_url'),
                              isDark: isDark,
                              inputBgColor: inputBgColor,
                              inputBorderColor: inputBorderColor,
                              textClr: textClr,
                              secClr: secClr,
                              activeBorderColor: blueClr,
                              maxLines: 3,
                              minLines: 1,
                              validator: (val) {
                                if (val == null || val.trim().isEmpty) {
                                  return L10n.of(context, 'url_empty_error');
                                }
                                // Validate each line separately for multi-URL support
                                final lines = val.split(RegExp(r'[\r\n]+'))
                                    .map((l) => l.trim())
                                    .where((l) => l.isNotEmpty)
                                    .toList();
                                if (lines.isEmpty) {
                                  return L10n.of(context, 'url_empty_error');
                                }
                                for (final line in lines) {
                                  if (!isValidTransmissionUrl(line)) {
                                    return L10n.of(context, 'url_invalid_error');
                                  }
                                }
                                return null;
                              },
                            ),
                            if (_urlController.text.trim().isNotEmpty)
                              Positioned(
                                right: 12.0,
                                top: 12.0,
                                child: Icon(
                                  _urlController.text.trim().split(RegExp(r'[\r\n]+'))
                                      .where((l) => l.trim().isNotEmpty)
                                      .every((l) => isValidTransmissionUrl(l.trim()))
                                      ? Icons.check_circle_rounded
                                      : Icons.cancel_rounded,
                                  color: _urlController.text.trim().split(RegExp(r'[\r\n]+'))
                                      .where((l) => l.trim().isNotEmpty)
                                      .every((l) => isValidTransmissionUrl(l.trim()))
                                      ? greenClr
                                      : redClr,
                                  size: 18,
                                ),
                              ),
                          ],
                        ),

                        const SizedBox(height: 12),

                        // Referrer link field
                        _buildTextField(
                          controller: _referrerController,
                          hint:
                              'Download/Referrer page link (leave empty if not sure)',
                          isDark: isDark,
                          inputBgColor: inputBgColor,
                          inputBorderColor: inputBorderColor,
                          textClr: textClr,
                          secClr: secClr,
                          activeBorderColor: blueClr,
                        ),

                        const SizedBox(height: 16),

                        // File name & Category labels
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: Text(
                                L10n.of(context, 'file_name_label'),
                                style: TextStyle(
                                  color: secClr,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                L10n.of(context, 'category_label'),
                                style: TextStyle(
                                  color: secClr,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),

                        // File name & Category inputs
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 2,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: _buildTextField(
                                      controller: _nameController,
                                      hint: 'Filename',
                                      isDark: isDark,
                                      inputBgColor: inputBgColor,
                                      inputBorderColor: inputBorderColor,
                                      textClr: textClr,
                                      secClr: secClr,
                                      activeBorderColor: blueClr,
                                      maxLines: 1,
                                      validator: (val) {
                                        if (val == null || val.trim().isEmpty) {
                                          return L10n.of(context, 'filename_empty_error');
                                        }
                                        return null;
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text('.', style: TextStyle(color: secClr, fontWeight: FontWeight.bold)),
                                  const SizedBox(width: 6),
                                  SizedBox(
                                    width: 60,
                                    child: _buildTextField(
                                      controller: _extController,
                                      hint: 'ext',
                                      isDark: isDark,
                                      inputBgColor: inputBgColor,
                                      inputBorderColor: inputBorderColor,
                                      textClr: textClr,
                                      secClr: secClr,
                                      activeBorderColor: blueClr,
                                      maxLines: 1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  color: inputBgColor,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: inputBorderColor),
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
                                    ),
                                    style: TextStyle(
                                      color: textClr,
                                      fontSize: 13,
                                    ),
                                    items: _categories.map((cat) {
                                      return DropdownMenuItem<String>(
                                        value: cat,
                                        child: Text(
                                          L10n.translateCategory(context, cat),
                                        ),
                                      );
                                    }).toList(),
                                    onChanged: (val) {
                                      if (val != null) {
                                        runHaptic(settings);
                                        setState(() => _selectedCategory = val);
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Save path section
                        Text(
                          L10n.of(context, 'save_path_label'),
                          style: TextStyle(
                            color: secClr,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: _buildTextField(
                                controller: _pathController,
                                hint: 'Save path',
                                isDark: isDark,
                                inputBgColor: inputBgColor,
                                inputBorderColor: inputBorderColor,
                                textClr: textClr,
                                secClr: secClr,
                                validator: (val) {
                                  if (val == null || val.trim().isEmpty) {
                                    return 'Save path cannot be empty';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: () async {
                                runHaptic(settings);
                                final result = await FilePicker.getDirectoryPath();
                                if (result != null) {
                                  setState(() {
                                    _pathController.text = result;
                                  });
                                }
                              },
                              icon: Icon(Icons.folder_open, color: blueClr),
                              style: IconButton.styleFrom(
                                backgroundColor: blueClr.withValues(alpha: 0.1),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Download options checkboxes & thread dropdown
                        Wrap(
                          spacing: 16,
                          runSpacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _buildCheckbox(
                              L10n.of(context, 'wifi_only_label'),
                              _wifiOnly,
                              (val) => setState(() => _wifiOnly = val ?? false),
                              blueClr,
                            ),
                            _buildCheckbox(
                              L10n.of(context, 'auto_retry_label'),
                              _retry,
                              (val) => setState(() => _retry = val ?? true),
                              greenClr,
                            ),
                            _buildCheckbox(
                              L10n.of(context, 'use_proxy_label'),
                              _useProxy,
                              (val) => setState(() => _useProxy = val ?? false),
                              orangeClr,
                            ),
                            _buildCheckbox(
                              L10n.isRtl(context) ? 'جدولة' : 'Schedule',
                              _isScheduled,
                              (val) => setState(() {
                                _isScheduled = val ?? false;
                                if (_isScheduled && _scheduledDateTime == null) {
                                  _scheduledDateTime = DateTime.now().add(const Duration(hours: 1));
                                }
                              }),
                              isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  L10n.of(context, 'threads_label'),
                                  style: TextStyle(
                                    color: secClr,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  decoration: BoxDecoration(
                                    color: inputBgColor,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: inputBorderColor),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<int>(
                                      dropdownColor: isDark
                                          ? AppTheme.surface
                                          : AppTheme.lightSurface,
                                      value: _selectedThreads,
                                      style: TextStyle(
                                        color: textClr,
                                        fontSize: 12,
                                      ),
                                      items: _threadsList.map((t) {
                                        return DropdownMenuItem<int>(
                                          value: t,
                                          child: Text('$t'),
                                        );
                                      }).toList(),
                                      onChanged: (val) {
                                        if (val != null) {
                                          runHaptic(settings);
                                          setState(() => _selectedThreads = val);
                                        }
                                      },
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Scheduled date/time picker
                        if (_isScheduled)
                          GestureDetector(
                            onTap: () async {
                              final now = DateTime.now();
                              final date = await showDatePicker(
                                context: context,
                                initialDate: _scheduledDateTime ?? now.add(const Duration(hours: 1)),
                                firstDate: now,
                                lastDate: now.add(const Duration(days: 365)),
                                builder: (ctx, child) {
                                  return Theme(
                                    data: Theme.of(ctx).copyWith(
                                      colorScheme: ColorScheme.dark(
                                        primary: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                                      ),
                                    ),
                                    child: child!,
                                  );
                                },
                              );
                              if (date != null && mounted) {
                                if (!context.mounted) return;
                                final time = await showTimePicker(
                                  context: context,
                                  initialTime: TimeOfDay.fromDateTime(
                                    _scheduledDateTime ?? now.add(const Duration(hours: 1)),
                                  ),
                                  builder: (ctx, child) {
                                    return Theme(
                                      data: Theme.of(ctx).copyWith(
                                        colorScheme: ColorScheme.dark(
                                          primary: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                                        ),
                                      ),
                                      child: child!,
                                    );
                                  },
                                );
                                if (time != null && mounted) {
                                  setState(() {
                                    _scheduledDateTime = DateTime(
                                      date.year, date.month, date.day,
                                      time.hour, time.minute,
                                    );
                                  });
                                }
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: inputBgColor,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: (isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet).withValues(alpha: 0.5),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.schedule,
                                    size: 16,
                                    color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    _scheduledDateTime != null
                                        ? '${_scheduledDateTime!.day}/${_scheduledDateTime!.month}/${_scheduledDateTime!.year} ${_scheduledDateTime!.hour.toString().padLeft(2, '0')}:${_scheduledDateTime!.minute.toString().padLeft(2, '0')}'
                                        : (L10n.isRtl(context) ? 'اختر الوقت' : 'Tap to set date & time'),
                                    style: TextStyle(
                                      color: textClr,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 16),

                        // Action Buttons
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: Text(
                                L10n.of(context, 'cancel_btn'),
                                style: TextStyle(
                                  color: secClr,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            if (_isResolvingLink)
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 16),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
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
                            NeonGlowButton(
                              onPressed: () {
                                if (_formKey.currentState!.validate()) {
                                  _handleDuplicateOrSubmit();
                                }
                              },
                              text: L10n.of(context, 'add_btn'),
                              icon: Icons.add_circle_outline,
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
            if (_isResolvingLink)
          Positioned.fill(
            child: Container(
              color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.3),
              child: Center(
                child: CircularProgressIndicator(
                  color: blueClr,
                ),
              ),
            ),
          ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required bool isDark,
    required Color inputBgColor,
    required Color inputBorderColor,
    required Color textClr,
    required Color secClr,
    Color? activeBorderColor,
    String? Function(String?)? validator,
    int? maxLines = 1,
    int? minLines = 1,
  }) {
    final focusColor = activeBorderColor ??
        (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);
    return Container(
      decoration: BoxDecoration(
        color: inputBgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: inputBorderColor, width: 1.0),
      ),
      child: TextFormField(
        controller: controller,
        style: TextStyle(color: textClr, fontSize: 13, height: 1.3),
        maxLines: maxLines,
        minLines: minLines,
        validator: validator,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            color: secClr.withValues(alpha: 0.5),
            fontSize: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: focusColor.withValues(alpha: 0.6),
              width: 1.2,
            ),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
                  .withValues(alpha: 0.6),
              width: 1.0,
            ),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
              width: 1.2,
            ),
          ),
          errorStyle: const TextStyle(fontSize: 10, height: 0.8),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 10,
          ),
        ),
      ),
    );
  }


  Widget _buildCheckbox(
    String title,
    bool value,
    ValueChanged<bool?> onChanged,
    Color activeColor,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 24,
          height: 24,
          child: Checkbox(
            value: value,
            activeColor: activeColor,
            side: BorderSide(
              color: activeColor.withValues(alpha: 0.5),
              width: 1.5,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            color: activeColor,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
