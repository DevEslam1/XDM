import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/domain/utils/url_specifications.dart';
import '../../../core/services/site_intelligence/site_intelligence_service.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/constants.dart';
import '../../../core/utils/url_utils.dart';
import '../../settings/provider/settings_provider.dart';

/// ViewModel managing state and operations for the Add Download dialog.
class AddDownloadViewModel extends ChangeNotifier {
  final SettingsProvider settingsProvider;

  String _url = '';
  String _name = '';
  String _ext = '';
  String _referrer = '';
  String _downloadPath = '';
  String _selectedCategory = 'Auto';
  int _selectedThreads = 5;
  bool _wifiOnly = false;
  bool _retry = true;
  bool _isScheduled = false;
  DateTime? _scheduledDateTime;
  bool _showAdvanced = false;
  bool _userEditedName = false;

  bool _isResolvingLink = false;
  bool _isMetadataResolved = false;
  bool _isSubmitting = false;
  String _resolvedFileName = '';
  int _resolvedFileSize = 0;
  int? _resolvedTorrentId;
  String _resolvedCategory = 'Auto';
  String? _resolvedYoutubeQualityPreset;
  String? _resolvedAudioUrl;
  int? _resolvedAudioSize;
  String? _resolvedThumbnailUrl;
  List<TorrentFileSelection> _torrentFiles = [];
  UrlAnalysisResult? _urlAnalysis;

  Timer? _ytDebounceTimer;
  Timer? _analysisDebounceTimer;
  String _lastCheckedUrl = '';

  AddDownloadViewModel({required this.settingsProvider}) {
    if (kAvailableThreadOptions.contains(settingsProvider.defaultThreadCount)) {
      _selectedThreads = settingsProvider.defaultThreadCount;
    }
    _wifiOnly = settingsProvider.wifiOnly;
  }

  // Getters
  String get url => _url;
  String get name => _name;
  String get ext => _ext;
  String get referrer => _referrer;
  String get downloadPath => _downloadPath;
  String get selectedCategory => _selectedCategory;
  int get selectedThreads => _selectedThreads;
  bool get wifiOnly => _wifiOnly;
  bool get retry => _retry;
  bool get isScheduled => _isScheduled;
  DateTime? get scheduledDateTime => _scheduledDateTime;
  bool get showAdvanced => _showAdvanced;
  bool get userEditedName => _userEditedName;

  bool get isResolvingLink => _isResolvingLink;
  bool get isMetadataResolved => _isMetadataResolved;
  bool get isSubmitting => _isSubmitting;
  String get resolvedFileName => _resolvedFileName;
  int get resolvedFileSize => _resolvedFileSize;
  int? get resolvedTorrentId => _resolvedTorrentId;
  String get resolvedCategory => _resolvedCategory;
  String? get resolvedYoutubeQualityPreset => _resolvedYoutubeQualityPreset;
  String? get resolvedAudioUrl => _resolvedAudioUrl;
  int? get resolvedAudioSize => _resolvedAudioSize;
  String? get resolvedThumbnailUrl => _resolvedThumbnailUrl;
  List<TorrentFileSelection> get torrentFiles => _torrentFiles;
  UrlAnalysisResult? get urlAnalysis => _urlAnalysis;

  bool get isTorrentOrMagnet {
    final raw = _url.trim();
    if (raw.isEmpty) return false;
    final lower = raw.toLowerCase();
    return lower.startsWith('magnet:') ||
        isMagnetUrl(raw) ||
        isTorrentFileUrl(raw) ||
        lower.endsWith('.torrent') ||
        lower.contains('.torrent?');
  }

  String get fullName {
    if (_ext.isEmpty) return _name;
    final dotExt = '.${_ext.toLowerCase()}';
    if (_name.toLowerCase().endsWith(dotExt)) return _name;
    return '$_name.$_ext';
  }

  void setReferrer(String ref) {
    _referrer = ref;
    notifyListeners();
  }

  void setDownloadPath(String path) {
    _downloadPath = path;
    notifyListeners();
  }

  void setSelectedCategory(String category) {
    _selectedCategory = category;
    notifyListeners();
  }

  void setSelectedThreads(int threads) {
    _selectedThreads = threads;
    notifyListeners();
  }

  void setWifiOnly(bool value) {
    _wifiOnly = value;
    notifyListeners();
  }

  void setRetry(bool value) {
    _retry = value;
    notifyListeners();
  }

  void setIsScheduled(bool value) {
    _isScheduled = value;
    notifyListeners();
  }

  void setScheduledDateTime(DateTime? dateTime) {
    _scheduledDateTime = dateTime;
    notifyListeners();
  }

  void setShowAdvanced(bool value) {
    _showAdvanced = value;
    notifyListeners();
  }

  void setUserEditedName(bool value) {
    _userEditedName = value;
  }

  void updateNameAndExt(String newName, String newExt) {
    _name = newName;
    _ext = newExt;
    notifyListeners();
  }

  void setNameFromFullName(String fullName) {
    _ext = p.extension(fullName).replaceFirst('.', '');
    _name = p.basenameWithoutExtension(fullName);
    notifyListeners();
  }

  void onUrlChanged(String rawUrl, {VoidCallback? onShouldResolveYoutube}) {
    final trimmed = rawUrl.trim();
    _url = trimmed;
    if (trimmed == _lastCheckedUrl) return;
    _lastCheckedUrl = trimmed;

    _ytDebounceTimer?.cancel();
    _analysisDebounceTimer?.cancel();

    if (trimmed.isNotEmpty) {
      _analysisDebounceTimer = Timer(const Duration(milliseconds: 300), () {
        _urlAnalysis = SiteIntelligenceService().analyzeUrl(trimmed);
        notifyListeners();
      });
    } else {
      _urlAnalysis = null;
    }

    if (trimmed.toLowerCase().startsWith('magnet:')) {
      final parsed = parseMagnetUrl(trimmed);
      final dnName = parsed['name'] ?? 'Torrent Download';
      if (!_userEditedName) {
        setNameFromFullName(dnName);
      }
      _resolvedFileName = _name.isNotEmpty ? fullName : dnName;
      _resolvedCategory = 'Archive';
      _selectedCategory = 'Archive';
      _isMetadataResolved = true;
      notifyListeners();
    } else if (YoutubeService.isExtractableMediaUrl(trimmed)) {
      if (!_isResolvingLink && !_isMetadataResolved) {
        _ytDebounceTimer = Timer(const Duration(milliseconds: 800), () {
          if (_url == trimmed) {
            onShouldResolveYoutube?.call();
          }
        });
      }
    } else {
      if (_isMetadataResolved &&
          _torrentFiles.isEmpty &&
          _resolvedFileSize == 0 &&
          _resolvedCategory == 'Archive') {
        _isMetadataResolved = false;
        _resolvedFileName = '';
        _resolvedTorrentId = null;
        _resolvedAudioUrl = null;
        _resolvedAudioSize = null;
        _resolvedThumbnailUrl = null;
      }
      notifyListeners();
    }
  }

  void setResolvedMetadata({
    required String fileName,
    required int fileSize,
    required String category,
    String? qualityPreset,
    String? audioUrl,
    int? audioSize,
    String? thumbnailUrl,
    int? torrentId,
    List<TorrentFileSelection>? files,
  }) {
    _resolvedFileName = fileName;
    _resolvedFileSize = fileSize;
    _resolvedCategory = category;
    _selectedCategory = category;
    _resolvedYoutubeQualityPreset = qualityPreset;
    _resolvedAudioUrl = audioUrl;
    _resolvedAudioSize = audioSize;
    _resolvedThumbnailUrl = thumbnailUrl;
    _resolvedTorrentId = torrentId;
    if (files != null) {
      _torrentFiles = files;
    }
    _isMetadataResolved = true;
    _isResolvingLink = false;
    notifyListeners();
  }

  void setResolvingState(bool resolving) {
    _isResolvingLink = resolving;
    notifyListeners();
  }

  void setSubmittingState(bool submitting) {
    _isSubmitting = submitting;
    notifyListeners();
  }

  @override
  void dispose() {
    _ytDebounceTimer?.cancel();
    _analysisDebounceTimer?.cancel();
    super.dispose();
  }
}
