import 'package:flutter/foundation.dart';
import '../../../core/services/youtube_service.dart';

/// ViewModel managing state and stream processing for the Media Quality Sheet.
class MediaQualityViewModel extends ChangeNotifier {
  final String videoUrl;
  final List<Map<String, dynamic>>? preloadedStreams;

  List<Map<String, dynamic>> _streams = [];
  List<Map<String, dynamic>> _memoizedVideos = [];
  List<Map<String, dynamic>> _memoizedAudios = [];
  bool _isLoading = true;
  String? _errorMessage;
  int _selectedTabIndex = 0;
  int _displayedVideoCount = 20;
  int _displayedAudioCount = 20;
  static bool hasSeenSilentVideoWarning = false;

  MediaQualityViewModel({
    required this.videoUrl,
    this.preloadedStreams,
  }) {
    if (preloadedStreams != null && preloadedStreams!.isNotEmpty) {
      _streams = preloadedStreams!;
      _isLoading = false;
      _processStreams();
    }
  }

  List<Map<String, dynamic>> get streams => _streams;
  List<Map<String, dynamic>> get videoList => _memoizedVideos;
  List<Map<String, dynamic>> get audioList => _memoizedAudios;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  int get selectedTabIndex => _selectedTabIndex;
  int get displayedVideoCount => _displayedVideoCount;
  int get displayedAudioCount => _displayedAudioCount;
  String get videoTitle =>
      _streams.isNotEmpty ? (_streams.first['title'] as String? ?? 'Media') : 'Media';

  void setSelectedTab(int index) {
    if (_selectedTabIndex != index) {
      _selectedTabIndex = index;
      notifyListeners();
    }
  }

  void loadMoreVideos() {
    if (_displayedVideoCount < _memoizedVideos.length) {
      _displayedVideoCount = (_displayedVideoCount + 20).clamp(0, _memoizedVideos.length);
      notifyListeners();
    }
  }

  void loadMoreAudios() {
    if (_displayedAudioCount < _memoizedAudios.length) {
      _displayedAudioCount = (_displayedAudioCount + 20).clamp(0, _memoizedAudios.length);
      notifyListeners();
    }
  }

  static int parseQuality(String q) {
    final match = RegExp(r'(\d+)').firstMatch(q);
    return match != null ? int.parse(match.group(1)!) : 0;
  }

  void _processStreams() {
    // Process audio streams
    _memoizedAudios = _streams.where((s) => s['type'] == 'audio').toList()
      ..sort((a, b) {
        final aSize = (a['size'] as num? ?? 0).toInt();
        final bSize = (b['size'] as num? ?? 0).toInt();
        return bSize.compareTo(aSize);
      });

    // Process and combine video streams
    final rawVideos = _streams
        .where((s) =>
            s['type'] == 'video_only' ||
            s['type'] == 'combined' ||
            s['type'] == 'muxed')
        .toList();

    final Map<int, Map<String, dynamic>> videosByHeight = {};
    for (final s in rawVideos) {
      final qStr = s['quality'] as String? ?? '';
      final h = parseQuality(qStr);
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

    _memoizedVideos = videosByHeight.entries.map((entry) {
      final h = entry.key;
      final v = entry.value;
      final vType = v['type'] as String? ?? 'muxed';
      if (_memoizedAudios.isNotEmpty &&
          (vType == 'video_only' ||
              v['audioSrc'] == null ||
              v['audioSrc'].toString().isEmpty)) {
        Map<String, dynamic> pairedAudio;
        if (h >= 720) {
          pairedAudio = _memoizedAudios.first;
        } else if (h == 480) {
          pairedAudio = _memoizedAudios[_memoizedAudios.length ~/ 2];
        } else {
          pairedAudio = _memoizedAudios.last;
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
        v['label'] ??= qLabel.isNotEmpty ? '$qLabel MP4' : 'Video MP4';
      }
      return v;
    }).toList()
      ..sort((a, b) {
        final aHeight = parseQuality(a['quality'] as String? ?? '');
        final bHeight = parseQuality(b['quality'] as String? ?? '');
        return bHeight.compareTo(aHeight);
      });
  }

  Future<void> fetchStreams() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await YoutubeService.fetchCookiesFromWebView();
      final streams = await YoutubeService.getStreamsForAnyUrl(videoUrl);
      _streams = streams ?? [];
      _isLoading = false;
      if (_streams.isEmpty) {
        _errorMessage = 'No streams found for this URL.';
      } else {
        _processStreams();
      }
    } catch (e) {
      _isLoading = false;
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    }
    notifyListeners();
  }
}
