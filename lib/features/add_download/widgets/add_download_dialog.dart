import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_theme.dart';
import '../../../core/di/injection.dart';
import '../../../core/interfaces/i_download_engine.dart';
import '../../../core/services/download_engine.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/site_intelligence/site_intelligence_service.dart';
import '../../../core/services/xdm_backend_exceptions.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/bencode_decoder.dart';
import '../../../core/utils/constants.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/url_utils.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/mixins/pausable_loop_animation.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../widgets/media_quality_sheet.dart';
import '../widgets/youtube_playlist_sheet.dart';

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
  // HTTP Basic auth + arbitrary custom request headers (Plan 06 Task 6.2).
  // Each header row owns its own key/value controllers so rows can be added
  // and removed independently.
  final TextEditingController _authUsernameController = TextEditingController();
  final TextEditingController _authPasswordController = TextEditingController();
  bool _obscureAuthPassword = true;
  final List<_CustomHeaderRow> _customHeaderRows = [];
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
    _urlFocus.addListener(_updateScanAnimation);
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
            _urlAnalysis = SiteIntelligenceService.instance.analyzeUrl(url);
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

  void _updateScanAnimation() {
    if (!mounted) return;
    final isDark = context.read<SettingsProvider>().isDarkMode;
    if (_urlFocus.hasFocus && isDark) {
      startPausableLoop();
    } else {
      stopPausableLoop();
    }
  }

  @override
  void dispose() {
    _urlFocus.removeListener(_updateScanAnimation);
    _urlController.removeListener(_onUrlChanged);
    _urlController.dispose();
    _referrerController.dispose();
    _nameController.dispose();
    _extController.dispose();
    _pathController.dispose();
    _authUsernameController.dispose();
    _authPasswordController.dispose();
    for (final row in _customHeaderRows) {
      row.dispose();
    }
    _urlFocus.dispose();
    _ytDebounceTimer?.cancel();
    _analysisDebounceTimer?.cancel();
    stopPausableLoop();
    _scanController.dispose();
    super.dispose();
  }

  // The three collectors below are consumed at the provider.addDownload()
  // call sites once DownloadTask gains auth/header params in the provider
  // (the model + DB already persist them). Kept here so the exact collection
  // logic lives with the UI that owns the controllers. See the seam comment at
  // the primary submit call (search: AUTH/HEADER SEAM).

  /// Collects the non-empty custom header rows into a map, or null if none.
  /// Rows with a blank key are skipped. Later rows win on duplicate keys.
  Map<String, String>? _collectCustomHeaders() {
    final map = <String, String>{};
    for (final row in _customHeaderRows) {
      final key = row.keyController.text.trim();
      if (key.isEmpty) continue;
      map[key] = row.valueController.text;
    }
    return map.isEmpty ? null : map;
  }

  String? get _authUsernameOrNull {
    final v = _authUsernameController.text.trim();
    return v.isEmpty ? null : v;
  }

  String? get _authPasswordOrNull {
    final v = _authPasswordController.text;
    return v.isEmpty ? null : v;
  }

  /// Deterministically picks the best stream for a bulk quality preset.
  /// Matches by parsed numeric height: exact first, then nearest ≤ chosen,
  /// then falls back to the first stream.
  static Map<String, dynamic> _pickBulkStream(
    List<Map<String, dynamic>> streams,
    String preset,
  ) {
    if (preset == 'audio_only') {
      return streams.firstWhere(
        (s) => s['type'] == 'audio',
        orElse: () => streams.first,
      );
    }
    final wanted = YoutubeService.parseQualityHeight(preset);
    if (wanted > 0) {
      Map<String, dynamic>? exact;
      Map<String, dynamic>? nearestBelow;
      var bestBelowGap = 1 << 30;
      for (final s in streams) {
        final h = YoutubeService.parseQualityHeight(
          (s['quality'] ?? s['label'] ?? '') as String? ?? '',
        );
        if (h == wanted) {
          exact ??= s;
        } else if (h > 0 && h < wanted && wanted - h < bestBelowGap) {
          bestBelowGap = wanted - h;
          nearestBelow = s;
        }
      }
      if (exact != null) return exact;
      if (nearestBelow != null) return nearestBelow;
    }
    return streams.first;
  }

  /// Shared input decoration for the advanced-section credential/header fields,
  /// matching the referrer/path field styling.
  InputDecoration _advInputDecoration({
    required String hint,
    required Color fillColor,
    required Color hintColor,
    required Color borderColor,
    required Color focusColor,
    required bool isDark,
    Widget? suffixIcon,
  }) {
    final errClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: hintColor, fontSize: 11),
      filled: true,
      fillColor: fillColor,
      isDense: true,
      suffixIcon: suffixIcon,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide:
            BorderSide(color: borderColor.withValues(alpha: 0.5), width: 0.8),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide:
            BorderSide(color: borderColor.withValues(alpha: 0.5), width: 0.8),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide:
            BorderSide(color: focusColor.withValues(alpha: 0.5), width: 1.2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide:
            BorderSide(color: errClr.withValues(alpha: 0.6), width: 1.0),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide:
            BorderSide(color: errClr.withValues(alpha: 0.8), width: 1.2),
      ),
    );
  }

  /// Builds the HTTP Basic-auth + custom-headers block shown in the advanced
  /// options section. Values are collected via [_authUsernameOrNull],
  /// [_authPasswordOrNull] and [_collectCustomHeaders] when submitting.
  Widget _buildCredentialsSection({
    required bool isRtl,
    required bool isDark,
    required Color textClr,
    required Color mutedClr,
    required Color panelBg,
    required Color borderClr,
    required Color blueClr,
  }) {
    final hintClr = mutedClr.withValues(alpha: 0.6);
    final monoStyle =
        TextStyle(color: textClr, fontSize: 12, fontFamily: 'monospace');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        _SectionLabel(
          text: isRtl
              ? 'مصادقة HTTP (اختياري)'
              : 'HTTP AUTHENTICATION (OPTIONAL)',
          color: mutedClr,
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                controller: _authUsernameController,
                style: monoStyle,
                autocorrect: false,
                enableSuggestions: false,
                decoration: _advInputDecoration(
                  hint: isRtl ? 'اسم المستخدم' : 'Username',
                  fillColor: panelBg,
                  hintColor: hintClr,
                  borderColor: borderClr,
                  focusColor: blueClr,
                  isDark: isDark,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                controller: _authPasswordController,
                style: monoStyle,
                obscureText: _obscureAuthPassword,
                autocorrect: false,
                enableSuggestions: false,
                decoration: _advInputDecoration(
                  hint: isRtl ? 'كلمة المرور' : 'Password',
                  fillColor: panelBg,
                  hintColor: hintClr,
                  borderColor: borderClr,
                  focusColor: blueClr,
                  isDark: isDark,
                  suffixIcon: IconButton(
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 36, minHeight: 36),
                    icon: Icon(
                      _obscureAuthPassword
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      size: 16,
                      color: mutedClr,
                    ),
                    onPressed: () => setState(
                        () => _obscureAuthPassword = !_obscureAuthPassword),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _SectionLabel(
          text: isRtl ? 'ترويسات مخصصة (اختياري)' : 'CUSTOM HEADERS (OPTIONAL)',
          color: mutedClr,
          trailing: GestureDetector(
            onTap: () =>
                setState(() => _customHeaderRows.add(_CustomHeaderRow())),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, size: 15, color: blueClr),
                const SizedBox(width: 2),
                Text(
                  isRtl ? 'إضافة' : 'ADD',
                  style: TextStyle(
                    color: blueClr,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
        ),
        for (final row in _customHeaderRows) ...[
          const SizedBox(height: 8),
          _buildHeaderRow(
            row: row,
            isRtl: isRtl,
            isDark: isDark,
            monoStyle: monoStyle,
            hintClr: hintClr,
            mutedClr: mutedClr,
            panelBg: panelBg,
            borderClr: borderClr,
            blueClr: blueClr,
          ),
        ],
      ],
    );
  }

  Widget _buildHeaderRow({
    required _CustomHeaderRow row,
    required bool isRtl,
    required bool isDark,
    required TextStyle monoStyle,
    required Color hintClr,
    required Color mutedClr,
    required Color panelBg,
    required Color borderClr,
    required Color blueClr,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          flex: 2,
          child: TextFormField(
            controller: row.keyController,
            style: monoStyle,
            autocorrect: false,
            enableSuggestions: false,
            decoration: _advInputDecoration(
              hint: isRtl ? 'الترويسة' : 'Header',
              fillColor: panelBg,
              hintColor: hintClr,
              borderColor: borderClr,
              focusColor: blueClr,
              isDark: isDark,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 3,
          child: TextFormField(
            controller: row.valueController,
            style: monoStyle,
            autocorrect: false,
            enableSuggestions: false,
            decoration: _advInputDecoration(
              hint: isRtl ? 'القيمة' : 'Value',
              fillColor: panelBg,
              hintColor: hintClr,
              borderColor: borderClr,
              focusColor: blueClr,
              isDark: isDark,
            ),
          ),
        ),
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          icon: Icon(Icons.close_rounded, size: 16, color: mutedClr),
          onPressed: () => setState(() {
            row.dispose();
            _customHeaderRows.remove(row);
          }),
        ),
      ],
    );
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
        .where((f) => isTorrentFileSelected(f))
        .fold<int>(0, (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0));
    setState(() => _resolvedFileSize = selectedTotal);
  }

  Future<void> _pickTorrentFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['torrent'],
      );
      if (result.isNotEmpty && result.single.path != null) {
        final filePath = result.single.path!;
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
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ThemedSnackbar.show(
        context,
        message: isRtl ? 'أدخل الرابط أولاً' : 'Enter a URL first',
        color: AppTheme.neonRed,
        icon: Icons.error_outline,
        isDarkMode: isDark,
      );
      return;
    }
    if (YoutubeService.isPlaylistUrl(url)) {
      final isMixed = YoutubeService.isYoutubeVideoUrl(url);
      if (isMixed && mounted) {
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) {
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
            ThemedSnackbar.show(
              context,
              message: isRtl
                  ? 'تم إضافة ${result.selectedVideos.length} فيديو'
                  : '${result.selectedVideos.length} videos enqueued',
              color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
              icon: Icons.playlist_add_check,
              isDarkMode: isDark,
            );
            Navigator.pop(context);
          }
          return;
        } else if (choice != 'video') {
          return;
        }
      } else if (!isMixed && mounted) {
        final result = await YoutubePlaylistSheet.show(context, url);
        if (result != null && mounted) {
          ThemedSnackbar.show(
            context,
            message: isRtl
                ? 'تم إضافة ${result.selectedVideos.length} فيديو'
                : '${result.selectedVideos.length} videos enqueued',
            color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
            icon: Icons.playlist_add_check,
            isDarkMode: isDark,
          );
          Navigator.pop(context);
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
        final streamUrl = (stream['src'] ?? stream['url'] ?? '') as String;
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
        try {
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
            message:
                L10n.isRtl(context) ? 'تم بدء التحميل' : 'Download started',
            color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
            icon: Icons.check_circle_outline,
            isDarkMode: isDark,
          );
          Navigator.pop(context);
          return;
        } catch (e) {
          if (!mounted) return;
          final isDark = context.read<SettingsProvider>().isDarkMode;
          ThemedSnackbar.show(
            context,
            message: 'Download failed: $e',
            color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
            icon: Icons.error_outline,
            isDarkMode: isDark,
          );
          return;
        }
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
      if (url.toLowerCase().startsWith('magnet:') || isMagnetUrl(url)) {
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
            _isMetadataResolved = true;
            _isResolvingLink = false;
          });
        }
        return;
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
      final engine = getIt<IDownloadEngine>();
      final nameForReq = _nameController.text.trim().isNotEmpty
          ? _composeFullName(
              _nameController.text.trim(), _extController.text.trim())
          : null;
      final DownloadMetadata meta = await engine.resolveMetadata(
        url: url,
        requestedFileName: nameForReq,
        customUserAgent: settings.customUserAgent,
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
      String? bulkQualityPreset;

      final firstExtractable = urls.firstWhere(
        (u) => YoutubeService.isExtractableMediaUrl(u),
        orElse: () => '',
      );
      if (firstExtractable.isNotEmpty && mounted) {
        final chosenStream =
            await MediaQualitySheet.show(context, firstExtractable);
        if (!mounted) return;
        if (chosenStream == null) {
          // User explicitly dismissed quality selection — abort bulk batch
          if (mounted) setState(() => _isSubmitting = false);
          return;
        }
        final streamType = chosenStream['type'] as String? ?? 'muxed';
        bulkQualityPreset = streamType == 'audio'
            ? 'audio_only'
            : chosenStream['quality'] as String?;
      }

      for (final singleUrl in urls) {
        if (!isValidTransmissionUrl(singleUrl)) {
          invalidCount++;
          continue;
        }
        if (AddDownloadDialog.wasRecentlyAdded(singleUrl)) {
          duplicateCount++;
          continue;
        }
        // FIX(H-16): Pace bulk imports to respect the backend rate limiter.
        // Without a delay between requests, pasting ~30+ YouTube links
        // guarantees mid-batch BackendRateLimitException failures.
        if (addedCount > 0) {
          await Future.delayed(const Duration(milliseconds: 500));
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
          if (YoutubeService.isExtractableMediaUrl(singleUrl)) {
            try {
              final streams =
                  await YoutubeService.getStreamsForAnyUrl(singleUrl);
              if (streams != null && streams.isNotEmpty) {
                final Map<String, dynamic> bestStream;
                if (bulkQualityPreset != null) {
                  bestStream = _pickBulkStream(streams, bulkQualityPreset);
                } else {
                  bestStream = streams.first;
                }
                final streamUrl =
                    (bestStream['src'] ?? bestStream['url'] ?? '') as String;
                final title =
                    bestStream['title'] as String? ?? 'Video Download';
                final ext = bestStream['ext'] as String? ?? 'mp4';
                final sName = safeFileName('$title.$ext');
                await provider.addDownload(
                  name: sName,
                  url: streamUrl,
                  size: (bestStream['size'] as num?)?.toInt() ?? 0,
                  category: bestStream['type'] == 'audio' ? 'Audio' : 'Video',
                  savePath: _pathController.text.trim().isNotEmpty
                      ? _pathController.text.trim()
                      : settings.customDownloadPath ?? '',
                  threadCount: _selectedThreads,
                  downloadPageUrl: singleUrl,
                  youtubeQualityPreset:
                      bulkQualityPreset ?? bestStream['quality'] as String?,
                  mergedAudioUrl: bestStream['audioSrc'] as String?,
                  audioSize: (bestStream['audioSize'] as num?)?.toInt() ?? 0,
                  thumbnailUrl: bestStream['thumbnailUrl'] as String?,
                  authUsername: _authUsernameOrNull,
                  authPassword: _authPasswordOrNull,
                  customHeaders: _collectCustomHeaders(),
                );
                addedCount++;
                AddDownloadDialog.recordAddedUrl(singleUrl);
                continue;
              }
            } catch (e, st) {
              debugPrint(
                '[AddDownloadDialog] Bulk media extract failed for $singleUrl: $e\n$st',
              );
              // FIX(H-16): When rate-limited, wait the indicated retry-after
              // window and retry once instead of silently dropping the URL.
              if (e is BackendRateLimitException &&
                  e.retryAfterSeconds != null) {
                await Future.delayed(
                  Duration(seconds: e.retryAfterSeconds!),
                );
                try {
                  final retryStreams =
                      await YoutubeService.getStreamsForAnyUrl(singleUrl);
                  if (retryStreams != null && retryStreams.isNotEmpty) {
                    // Use the first stream as best-effort
                    final stream = retryStreams.first;
                    final streamUrl =
                        (stream['src'] ?? stream['url'] ?? '') as String;
                    final title =
                        stream['title'] as String? ?? 'Video Download';
                    final ext = stream['ext'] as String? ?? 'mp4';
                    final sName = safeFileName('$title.$ext');
                    await provider.addDownload(
                      name: sName,
                      url: streamUrl,
                      size: (stream['size'] as num?)?.toInt() ?? 0,
                      category: stream['type'] == 'audio' ? 'Audio' : 'Video',
                      savePath: _pathController.text.trim().isNotEmpty
                          ? _pathController.text.trim()
                          : settings.customDownloadPath ?? '',
                      threadCount: _selectedThreads,
                      downloadPageUrl: singleUrl,
                      authUsername: _authUsernameOrNull,
                      authPassword: _authPasswordOrNull,
                      customHeaders: _collectCustomHeaders(),
                    );
                    addedCount++;
                    AddDownloadDialog.recordAddedUrl(singleUrl);
                    continue;
                  }
                } catch (_) {
                  // Give up after rate-limit retry; fall through to raw URL
                }
              }
            }
          }
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
            authUsername: _authUsernameOrNull,
            authPassword: _authPasswordOrNull,
            customHeaders: _collectCustomHeaders(),
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
    final singleUrl = urls.isNotEmpty ? urls.first : '';
    if (urls.length == 1 &&
        YoutubeService.isExtractableMediaUrl(singleUrl) &&
        !_isMetadataResolved) {
      if (mounted) setState(() => _isSubmitting = false);
      await _resolveLinkMetadata();
      return;
    }
    final enteredName = _nameController.text.trim();
    final enteredExt = _extController.text.trim();
    final String fullEnteredName = _composeFullName(enteredName, enteredExt);
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
                  final confirmed = await showDialog<bool>(
                    context: dialogContext,
                    builder: (ctx) => AlertDialog(
                      backgroundColor:
                          isDark ? AppTheme.surface : AppTheme.lightSurface,
                      title: Text(
                        isRtl ? 'تأكيد البدء من جديد' : 'Confirm Restart',
                        style: TextStyle(
                            color: isDark
                                ? AppTheme.neonRed
                                : AppTheme.lightNeonRed),
                      ),
                      content: Text(
                        isRtl
                            ? 'سيتم حذف التقدم الحالي والبدء من الصفر. هل أنت متأكد؟'
                            : 'This will clear all existing progress and restart from zero. Are you sure?',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(isRtl ? 'إلغاء' : 'Cancel'),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: (isDark
                                    ? AppTheme.neonRed
                                    : AppTheme.lightNeonRed)
                                .withValues(alpha: 0.2),
                          ),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(
                            isRtl ? 'نعم، ابدأ من جديد' : 'Yes, Start Over',
                            style: TextStyle(
                                color: isDark
                                    ? AppTheme.neonRed
                                    : AppTheme.lightNeonRed),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                  if (!dialogContext.mounted) return;
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
                      authUsername: _authUsernameOrNull,
                      authPassword: _authPasswordOrNull,
                      customHeaders: _collectCustomHeaders(),
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
      try {
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
          authUsername: _authUsernameOrNull,
          authPassword: _authPasswordOrNull,
          customHeaders: _collectCustomHeaders(),
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
          if (mounted) setState(() => _isSubmitting = false);
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
      } catch (e) {
        if (mounted) {
          setState(() => _isSubmitting = false);
          ThemedSnackbar.show(
            context,
            message: e.toString(),
            color: redClr,
            icon: Icons.error_outline,
            isDarkMode: isDark,
          );
        }
      } finally {
        if (mounted) setState(() => _isSubmitting = false);
      }
    }
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
    final isAmoled = settings.isAmoledMode;
    final isRtl = L10n.isRtl(context);
    final textClr = AppTheme.textPrimaryOf(isDark);
    final secClr = AppTheme.textSecondaryOf(isDark);
    final mutedClr = AppTheme.textMutedOf(isDark);
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);
    final panelBg = AppTheme.panelBg(isDark, isAmoled: isAmoled);
    final sheetSurface = AppTheme.sheetSurface(isDark, isAmoled: isAmoled);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: DmxTokens.sheetMaxWidth),
        child: Container(
          decoration: AppTheme.sheetDecoration(
            isDark: isDark,
            isAmoled: isAmoled,
            radius: DmxTokens.sheetRadius,
            roundedAll: true,
            backgroundColor: sheetSurface,
            accentColor: blueClr,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(DmxTokens.sheetRadius),
            child: Material(
              color: Colors.transparent,
              child: AbsorbPointer(
                absorbing:
                    (_isResolvingLink && !_isTorrentOrMagnet) || _isSubmitting,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Unified Sheet Header
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        20,
                        16,
                        12,
                        14,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: blueClr.withValues(
                                alpha: isDark ? 0.14 : 0.10,
                              ),
                              borderRadius: BorderRadius.circular(
                                DmxTokens.badgeRadius,
                              ),
                              border: Border.all(
                                color: blueClr.withValues(
                                  alpha: isDark ? 0.24 : 0.20,
                                ),
                                width: 0.8,
                              ),
                            ),
                            child: Icon(
                              Icons.download_rounded,
                              color: blueClr,
                              size: 19,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  L10n.of(context, 'download_file_title'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: textClr,
                                    fontFamily: AppTheme.fontDisplay,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.1,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  isRtl
                                      ? 'إشارة تنزيل جديدة'
                                      : 'NEW TRANSMISSION SIGNAL',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTheme.microLabel(
                                    isDark: isDark,
                                    color: mutedClr,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          _HeaderAction(
                            icon: Icons.content_paste_rounded,
                            tooltip: isRtl ? 'لصق' : 'Paste',
                            color: secClr,
                            isDark: isDark,
                            onTap: _pasteFromClipboard,
                          ),
                          const SizedBox(width: 4),
                          _HeaderAction(
                            icon: Icons.language_rounded,
                            tooltip:
                                isRtl ? 'فتح في المتصفح' : 'Open in browser',
                            color: secClr,
                            isDark: isDark,
                            onTap: () => _openUrlInBrowser(isRtl),
                          ),
                          const SizedBox(width: 4),
                          _HeaderAction(
                            icon: Icons.close_rounded,
                            tooltip: isRtl ? 'إغلاق' : 'Close',
                            color: mutedClr,
                            isDark: isDark,
                            filled: true,
                            onTap: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, thickness: 0.8, color: borderClr),
                    // Scrollable Form Body
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
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
                                          color:
                                              violetClr.withValues(alpha: 0.10),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          border: Border.all(
                                            color: violetClr.withValues(
                                                alpha: 0.3),
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
                              RepaintBoundary(
                                child: AnimatedContainer(
                                  duration: AppTheme.motionFast,
                                  decoration: BoxDecoration(
                                    color: panelBg,
                                    borderRadius: BorderRadius.circular(
                                        DmxTokens.radiusMd),
                                    border: Border.all(
                                      color: _urlController.text.trim().isEmpty
                                          ? (_urlFocus.hasFocus
                                              ? blueClr
                                              : borderClr)
                                          : (_urlValid ? greenClr : redClr),
                                      width: _urlFocus.hasFocus ||
                                              _urlController.text
                                                  .trim()
                                                  .isNotEmpty
                                          ? 1.2
                                          : 0.8,
                                    ),
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
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxHeight: 120,
                                        ),
                                        child: TextFormField(
                                          controller: _urlController,
                                          focusNode: _urlFocus,
                                          autocorrect: false,
                                          enableSuggestions: false,
                                          keyboardType: TextInputType.url,
                                          maxLines: null,
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
                                              if (line.startsWith('magnet:') &&
                                                  !isMagnetUrl(line)) {
                                                return 'Invalid magnet link format';
                                              }
                                              if (!isValidTransmissionUrl(
                                                  line)) {
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
                                              borderRadius:
                                                  BorderRadius.circular(
                                                12,
                                              ),
                                              borderSide: BorderSide.none,
                                            ),
                                            enabledBorder: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(
                                                12,
                                              ),
                                              borderSide: BorderSide.none,
                                            ),
                                            focusedBorder: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(
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
                                              borderRadius:
                                                  BorderRadius.circular(
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
                                              borderRadius:
                                                  BorderRadius.circular(
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
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (_urlAnalysis != null &&
                                  _urlController.text.isNotEmpty)
                                Padding(
                                  padding:
                                      const EdgeInsets.only(top: 6, bottom: 2),
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        _SectionLabel(
                                          text: L10n.of(
                                              context, 'file_name_label'),
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
                                                onChanged: (v) =>
                                                    _userEditedName =
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
                                                      const EdgeInsets
                                                          .symmetric(
                                                    horizontal: 12,
                                                    vertical: 11,
                                                  ),
                                                  border: OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            12),
                                                    borderSide: BorderSide(
                                                      color:
                                                          borderClr.withValues(
                                                        alpha: 0.5,
                                                      ),
                                                      width: 0.8,
                                                    ),
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            12),
                                                    borderSide: BorderSide(
                                                      color:
                                                          borderClr.withValues(
                                                        alpha: 0.5,
                                                      ),
                                                      width: 0.8,
                                                    ),
                                                  ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            12),
                                                    borderSide: BorderSide(
                                                      color: blueClr.withValues(
                                                        alpha: 0.5,
                                                      ),
                                                      width: 1.2,
                                                    ),
                                                  ),
                                                  errorBorder:
                                                      OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            12),
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
                                              padding:
                                                  const EdgeInsets.symmetric(
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
                                                      const EdgeInsets
                                                          .symmetric(
                                                    horizontal: 10,
                                                    vertical: 11,
                                                  ),
                                                  border: OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            12),
                                                    borderSide: BorderSide(
                                                      color:
                                                          borderClr.withValues(
                                                        alpha: 0.5,
                                                      ),
                                                      width: 0.8,
                                                    ),
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            12),
                                                    borderSide: BorderSide(
                                                      color:
                                                          borderClr.withValues(
                                                        alpha: 0.5,
                                                      ),
                                                      width: 0.8,
                                                    ),
                                                  ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            12),
                                                    borderSide: BorderSide(
                                                      color: blueClr.withValues(
                                                        alpha: 0.5,
                                                      ),
                                                      width: 1.2,
                                                    ),
                                                  ),
                                                  errorBorder:
                                                      OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            12),
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        _SectionLabel(
                                          text: L10n.of(
                                              context, 'category_label'),
                                          color: mutedClr,
                                        ),
                                        const SizedBox(height: 8),
                                        Container(
                                          decoration: BoxDecoration(
                                            color: panelBg,
                                            borderRadius:
                                                BorderRadius.circular(12),
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
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                );
                                              }).toList(),
                                              onChanged: (val) {
                                                if (val != null) {
                                                  runHaptic(settings);
                                                  setState(
                                                    () =>
                                                        _selectedCategory = val,
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
                                              border:
                                                  Border.all(color: borderClr),
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
                                                        fontFamily:
                                                            'Space Grotesk',
                                                        fontWeight:
                                                            FontWeight.bold,
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
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
                                              label:
                                                  isRtl ? 'واي فاي' : 'WI-FI',
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
                                              onTap: () => setState(
                                                  () => _retry = !_retry),
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
                                  setState(
                                      () => _showAdvanced = !_showAdvanced);
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
                                        duration:
                                            const Duration(milliseconds: 200),
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
                                firstChild:
                                    const SizedBox(width: double.infinity),
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
                                          color:
                                              mutedClr.withValues(alpha: 0.6),
                                          fontSize: 11,
                                        ),
                                        filled: true,
                                        fillColor: panelBg,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                          horizontal: 14,
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
                                            color:
                                                blueClr.withValues(alpha: 0.5),
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
                                        focusedErrorBorder: OutlineInputBorder(
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
                                    _buildCredentialsSection(
                                      isRtl: isRtl,
                                      isDark: isDark,
                                      textClr: textClr,
                                      mutedClr: mutedClr,
                                      panelBg: panelBg,
                                      borderClr: borderClr,
                                      blueClr: blueClr,
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
                                                          : AppTheme
                                                              .lightNeonRed)
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
                                                          : AppTheme
                                                              .lightNeonRed)
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
                                              final uri = await FilePicker
                                                      .pickDirectory()
                                                  .timeout(
                                                const Duration(seconds: 30),
                                              );
                                              if (uri != null) {
                                                final result =
                                                    uri.scheme == 'file'
                                                        ? uri.toFilePath()
                                                        : uri.toString();
                                                setState(
                                                  () => _pathController.text =
                                                      result,
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
                                                  isDarkMode:
                                                      settings.isDarkMode,
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
                                            _scheduledDateTime =
                                                DateTime.now().add(
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
                                                now.add(
                                                    const Duration(hours: 1)),
                                            firstDate: now,
                                            lastDate: now.add(
                                              const Duration(days: 365),
                                            ),
                                          );
                                          if (date != null && mounted) {
                                            if (!context.mounted) return;
                                            final time = await showTimePicker(
                                              context: context,
                                              initialTime:
                                                  TimeOfDay.fromDateTime(
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
                                            borderRadius:
                                                BorderRadius.circular(10),
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
                                sizeCurve: Curves.easeInOut,
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
                                    _torrentFiles[i]['priority'] = v ? 4 : 0;
                                    _updateSelectedTorrentSize();
                                  },
                                  onSelectAll: (v) {
                                    for (final f in _torrentFiles) {
                                      f['selected'] = v;
                                      f['priority'] = v ? 4 : 0;
                                    }
                                    _updateSelectedTorrentSize();
                                  },
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Pinned Action Bar Footer
                    Divider(height: 1, thickness: 0.8, color: borderClr),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                      child: Row(
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            style: TextButton.styleFrom(
                              foregroundColor: redClr,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                            child: Text(
                              L10n.of(context, 'cancel_btn'),
                              style: const TextStyle(
                                fontFamily: AppTheme.fontDisplay,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          const Spacer(),
                          if (_isResolvingLink)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
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
                                      fontFamily: AppTheme.fontDisplay,
                                      color: blueClr,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.6,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            OutlinedButton(
                              onPressed: _resolveLinkMetadata,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: blueClr,
                                side: BorderSide(
                                  color: blueClr.withValues(alpha: 0.45),
                                  width: 1,
                                ),
                                minimumSize: const Size(0, 44),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    DmxTokens.radiusMd,
                                  ),
                                ),
                              ),
                              child: Text(
                                L10n.of(context, 'connect_btn'),
                                style: const TextStyle(
                                  fontFamily: AppTheme.fontDisplay,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed:
                                ((_isResolvingLink && !_isTorrentOrMagnet) ||
                                        _isSubmitting)
                                    ? null
                                    : () {
                                        if (_formKey.currentState!.validate()) {
                                          _handleDuplicateOrSubmit();
                                        }
                                      },
                            icon: ((_isResolvingLink && !_isTorrentOrMagnet) ||
                                    _isSubmitting)
                                ? SizedBox(
                                    width: 15,
                                    height: 15,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppTheme.inkOn(greenClr),
                                    ),
                                  )
                                : const Icon(
                                    Icons.add_circle_outline_rounded,
                                    size: 18,
                                  ),
                            label: Text(
                              (_isResolvingLink && !_isTorrentOrMagnet)
                                  ? (isRtl
                                      ? 'إنتظار الاتصال...'
                                      : 'Connecting...')
                                  : _isSubmitting
                                      ? (isRtl
                                          ? 'جاري الإضافة...'
                                          : 'Adding...')
                                      : L10n.of(context, 'add_btn'),
                              style: const TextStyle(
                                fontFamily: AppTheme.fontDisplay,
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 44),
                              backgroundColor: greenClr,
                              foregroundColor: AppTheme.inkOn(greenClr),
                              disabledBackgroundColor:
                                  greenClr.withValues(alpha: 0.4),
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  DmxTokens.radiusMd,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openUrlInBrowser(bool isRtl) async {
    final messenger = ScaffoldMessenger.of(context);
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      messenger.removeCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 2600),
          content: Text(
            isRtl ? 'لا يوجد رابط لفتحه' : 'No URL to open',
          ),
        ),
      );
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      messenger.removeCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 2600),
          content: Text(
            isRtl ? 'لا يمكن فتح الرابط' : 'Cannot open URL',
          ),
        ),
      );
    }
  }
}

/// Holds the editable key/value controllers for a single custom-header row in
/// the add-download advanced options section.
class _CustomHeaderRow {
  final TextEditingController keyController;
  final TextEditingController valueController;

  _CustomHeaderRow({String key = '', String value = ''})
      : keyController = TextEditingController(text: key),
        valueController = TextEditingController(text: value);

  void dispose() {
    keyController.dispose();
    valueController.dispose();
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final Color color;
  final Widget? trailing;
  const _SectionLabel({required this.text, required this.color, this.trailing});
  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: AppTheme.fontDisplay,
        color: color,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.7,
      ),
    );
    if (trailing == null) return label;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(child: label),
        trailing!,
      ],
    );
  }
}

class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final bool isDark;
  final bool filled;
  final VoidCallback onTap;
  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.isDark,
    this.filled = false,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: Material(
        color: filled
            ? (isDark
                ? AppTheme.surfaceRaised.withValues(alpha: 0.7)
                : AppTheme.lightBgSunken.withValues(alpha: 0.9))
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              child: Icon(icon, size: 19, color: color),
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
        ? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue)
        : (analysis.siteType == SiteType.magnetSource
            ? (isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet)
            : (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen));
    final icon = (analysis.siteType == SiteType.videoStreaming ||
            analysis.contentHint == ContentHint.videoFile)
        ? Icons.play_circle_outline_rounded
        : (analysis.siteType == SiteType.magnetSource
            ? Icons.link_rounded
            : Icons.info_outline_rounded);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: isDark ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
        border: Border.all(color: accent.withValues(alpha: 0.3), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: accent),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${analysis.profile?.displayName ?? analysis.siteType.name.toUpperCase()} • ${analysis.contentHint.name.replaceAll(RegExp(r"(?=[A-Z])"), " ").toUpperCase()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AppTheme.fontDisplay,
                color: accent,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
          if (analysis.detectedQuality != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                analysis.detectedQuality!,
                style: TextStyle(
                  fontFamily: AppTheme.fontDisplay,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.inkOn(accent),
                ),
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
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
            border: Border.all(color: color.withValues(alpha: 0.3), width: 0.8),
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
        borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 17,
            color: onTap == null ? color.withValues(alpha: 0.3) : color,
          ),
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
    final muted = AppTheme.textMutedOf(isDark);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppTheme.motionFast,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? color.withValues(alpha: isDark ? 0.14 : 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
          border: Border.all(
            color: active
                ? color.withValues(alpha: 0.45)
                : AppTheme.hairlineBorder(isDark),
            width: active ? 1.0 : 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: active ? color : muted),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontFamily: AppTheme.fontDisplay,
                color: active ? color : muted,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
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
          size: 16,
          color: value ? color : AppTheme.textMutedOf(isDark),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: AppTheme.fontBody,
              color: AppTheme.textPrimaryOf(isDark),
              fontSize: 13,
              fontWeight: FontWeight.w500,
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
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        border: Border.all(color: violet.withValues(alpha: 0.3), width: 0.8),
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
                      fontFamily: AppTheme.fontDisplay,
                      color: AppTheme.textPrimaryOf(isDark),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => onSelectAll(true),
                  child: Text(
                    L10n.isRtl(context) ? 'الكل' : 'ALL',
                    style: TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      fontSize: 11,
                      color: violet,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => onSelectAll(false),
                  child: Text(
                    L10n.isRtl(context) ? 'إلغاء' : 'NONE',
                    style: TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      fontSize: 11,
                      color: AppTheme.textMutedOf(isDark),
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
              color: AppTheme.surfaceColor(isDark, elevated: false),
              borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
            ),
            child: ListView.separated(
              physics: const ClampingScrollPhysics(),
              itemCount: files.length,
              separatorBuilder: (context, index) =>
                  Divider(color: borderClr, height: 1, thickness: 0.6),
              itemBuilder: (ctx, idx) {
                final file = files[idx];
                final isSelected = file['selected'] as bool? ?? true;
                final fileName =
                    (file['name'] as String? ?? '').replaceAll('+', ' ');
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
                        fontFamily: AppTheme.fontBody,
                        color: isSelected
                            ? AppTheme.textPrimaryOf(isDark)
                            : AppTheme.textSecondaryOf(isDark),
                        fontSize: 12,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.normal,
                        decoration:
                            isSelected ? null : TextDecoration.lineThrough,
                      ),
                    ),
                    subtitle: Text(
                      formatBytes(length.toDouble()),
                      style: AppTheme.dataStyle(
                        isDark: isDark,
                        size: 11,
                        color: AppTheme.textMutedOf(isDark),
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
