import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../../../core/services/site_intelligence/site_intelligence_service.dart';
import '../../../core/services/youtube_service.dart';
import '../models/browser_tab.dart';

/// Detects downloadable media on browser pages (REFACTOR B extraction from
/// `_BrowserScreenState`).
///
/// Owns all per-tab detection state and runs the media-scan JavaScript on the
/// tab's WebView. It does NOT manage UI: the host screen listens through
/// [onStateChanged] and renders FABs/sheets from the exposed maps.
class MediaSniffer extends ChangeNotifier {
  static final _log = Logger('MediaSniffer');
  MediaSniffer({
    required this.isActive,
    required this.containsTab,
    required this.isSnifferEnabled,
    this.onStateChanged,
  });

  /// Whether the host screen is still mounted.
  final bool Function() isActive;

  /// Whether [tab] is still one of the open tabs.
  final bool Function(BrowserTab tab) containsTab;

  /// Whether the media sniffer toggle is enabled.
  final bool Function() isSnifferEnabled;

  /// Notifies the host that detection state changed (triggers setState).
  final VoidCallback? onStateChanged;

  /// tabId -> best single downloadable URL for the page.
  final Map<String, String> detectedDownloadUrls = {};

  /// tabId -> all detected media sources on the page.
  final Map<String, List<Map<String, dynamic>>> detectedMediaSources = {};

  /// tabId -> video count of a detected YouTube playlist.
  final Map<String, int> detectedPlaylistUrls = {};

  /// url -> when YouTube stream detection last failed for it.
  final Map<String, DateTime> ytDetectionFailed = {};

  /// tabId -> whether the DOM media scan failed.
  final Map<String, bool> mediaScanFailed = {};

  /// Per-tab YouTube auth cooldown — prevents one tab's auth suppressing others.
  final Map<String, DateTime> lastYoutubeAuthTimes = {};

  /// tabId -> pending debounce timer for a scheduled scan.
  final Map<String, Timer> mediaScanTimers = {};

  /// tabId -> set of scanned URLs.
  final Map<String, Set<String>> _tabUrls = {};

  int get totalDetectedCount =>
      detectedDownloadUrls.length +
      detectedMediaSources.values
          .fold<int>(0, (sum, list) => sum + list.length) +
      detectedPlaylistUrls.length;

  void clearAll() {
    _update(() {
      cancelAllScanTimers();
      detectedDownloadUrls.clear();
      detectedMediaSources.clear();
      detectedPlaylistUrls.clear();
      mediaScanFailed.clear();
      _tabUrls.clear();
    });
  }

  static bool isYoutubeHost(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtu.be';
  }

  /// Mutates detection state and notifies the host, mirroring the original
  /// `setState(() {...})` calls.
  void _update(VoidCallback fn) {
    fn();
    notifyListeners();
    onStateChanged?.call();
  }

  /// Removes all per-tab state when a tab is closed or navigated away.
  /// Call this from every tab-close path to prevent unbounded map growth.
  void cleanupTab(String tabId) {
    mediaScanTimers[tabId]?.cancel();
    mediaScanTimers.remove(tabId);
    detectedDownloadUrls.remove(tabId);
    detectedMediaSources.remove(tabId);
    detectedPlaylistUrls.remove(tabId);
    lastYoutubeAuthTimes.remove(tabId);
    mediaScanFailed.remove(tabId);

    final urls = _tabUrls.remove(tabId);
    if (urls != null) {
      for (final u in urls) {
        ytDetectionFailed.remove(u);
      }
    }

    // Evict expired entries older than 10 minutes or if exceeding 200 entries
    final now = DateTime.now();
    ytDetectionFailed.removeWhere(
      (url, timestamp) =>
          now.difference(timestamp) > const Duration(minutes: 10),
    );
    if (ytDetectionFailed.length > 200) {
      final sortedKeys = ytDetectionFailed.keys.toList()
        ..sort(
            (a, b) => ytDetectionFailed[a]!.compareTo(ytDetectionFailed[b]!));
      final toRemoveCount = ytDetectionFailed.length - 200;
      for (int i = 0; i < toRemoveCount; i++) {
        ytDetectionFailed.remove(sortedKeys[i]);
      }
    }
  }

  /// Cancels all scheduled media scan timers.
  void cancelAllScanTimers() {
    for (final timer in mediaScanTimers.values) {
      timer.cancel();
    }
    mediaScanTimers.clear();
  }

  /// Schedules a debounced media scan for the given tab.
  void scheduleScan(BrowserTab tab, {List<BrowserTab>? tabs}) {
    mediaScanTimers[tab.id]?.cancel();
    mediaScanTimers[tab.id] = Timer(const Duration(milliseconds: 800), () {
      scanPageMedia(tab, tabs: tabs ?? [tab]);
    });
  }

  /// Cancels all pending scan timers and clears detection state.
  @override
  void dispose() {
    for (final timer in mediaScanTimers.values) {
      timer.cancel();
    }
    mediaScanTimers.clear();
    detectedDownloadUrls.clear();
    detectedMediaSources.clear();
    detectedPlaylistUrls.clear();
    ytDetectionFailed.clear();
    mediaScanFailed.clear();
    lastYoutubeAuthTimes.clear();
    _tabUrls.clear();
    super.dispose();
  }

  Future<void> scanPageMedia(
    BrowserTab tab, {
    required List<BrowserTab> tabs,
  }) async {
    if (!isActive() || !containsTab(tab) || tab.isHome || !isSnifferEnabled()) {
      return;
    }
    mediaScanFailed.remove(tab.id);
    if (isYoutubeHost(tab.url)) return;
    final scannedUrl = tab.url;

    _tabUrls.putIfAbsent(tab.id, () => <String>{}).add(scannedUrl);

    // FIX-INTEL: Check for known streaming sites for specialized sniffing
    final analysis = SiteIntelligenceService().analyzeUrl(scannedUrl);
    final isSpecialized = analysis.siteType == SiteType.videoStreaming ||
        analysis.siteType == SiteType.audioStreaming;
    if (isSpecialized) {
      _log.fine(
          'Specialized media sniffing active for ${analysis.profile?.displayName ?? scannedUrl}');
    }

    final activeIds = tabs.map((t) => t.id).toSet();
    final staleKeys = detectedMediaSources.keys
        .where((key) => !activeIds.contains(key))
        .toList();
    for (final key in staleKeys) {
      detectedMediaSources.remove(key);
      detectedDownloadUrls.remove(key);
      detectedPlaylistUrls.remove(key);
      mediaScanFailed.remove(key);
      lastYoutubeAuthTimes.remove(key);
    }
    if (ytDetectionFailed.length > 200) {
      final cutoff = DateTime.now().subtract(const Duration(minutes: 30));
      ytDetectionFailed.removeWhere((_, v) => v.isBefore(cutoff));
    }
    if (YoutubeService.isPlaylistUrl(scannedUrl)) {
      try {
        final info = await YoutubeService.getPlaylistInfo(scannedUrl)
            .timeout(const Duration(seconds: 15));
        if (info != null && isActive() && tab.url == scannedUrl) {
          final count = info['videoCount'] as int? ?? 0;
          _update(() {
            detectedPlaylistUrls[tab.id] = count;
            detectedDownloadUrls[tab.id] = scannedUrl;
          });
        }
      } catch (e) {
        _log.warning('YouTube playlist scan error: $e');
      }
      if (YoutubeService.isYoutubeVideoUrl(scannedUrl)) {
        try {
          final youtubeStreams = await YoutubeService.getStreams(scannedUrl)
              .timeout(const Duration(seconds: 15));
          if (youtubeStreams.isNotEmpty &&
              isActive() &&
              tab.url == scannedUrl) {
            _update(() {
              detectedMediaSources[tab.id] = youtubeStreams;
            });
          }
        } catch (e) {
          _log.warning('YouTube single stream scan error after playlist: $e');
        }
      }
      return;
    }
    if (YoutubeService.isYoutubeVideoUrl(scannedUrl)) {
      try {
        final youtubeStreams = await YoutubeService.getStreams(scannedUrl)
            .timeout(const Duration(seconds: 15));
        if (youtubeStreams.isNotEmpty && isActive() && tab.url == scannedUrl) {
          _update(() {
            detectedMediaSources[tab.id] = youtubeStreams;
            ytDetectionFailed.remove(scannedUrl);
            if (detectedDownloadUrls[tab.id] == null) {
              detectedDownloadUrls[tab.id] = youtubeStreams.first['src'];
            }
          });
          return;
        }
      } catch (e) {
        _log.warning('YouTube stream detection error: $e');
      }
      if (isActive() && tab.url == scannedUrl) {
        _update(() {
          ytDetectionFailed[scannedUrl] = DateTime.now();
          if (ytDetectionFailed.length > 200) {
            final oldestKey = ytDetectionFailed.entries
                .reduce((a, b) => a.value.isBefore(b.value) ? a : b)
                .key;
            ytDetectionFailed.remove(oldestKey);
          }
        });
      }
    }
    try {
      final result = await tab.controller?.evaluateJavascript(source: '''
(function() {
  var hasMediaTags = document.querySelector('video, audio, iframe, [data-src], [data-video-src]');
  var hasPerf = false;
  try {
    var res = window.performance.getEntriesByType('resource');
    for (var k = 0; k < res.length; k++) {
      var n = res[k].name;
      if (n && (n.indexOf('.m3u8') !== -1 || n.indexOf('.mpd') !== -1 || n.indexOf('.mp4') !== -1)) {
        hasPerf = true;
        break;
      }
    }
  } catch(e) {}
  if (!hasMediaTags && !hasPerf) return '[]';

  var sources = [];
  var videos = document.getElementsByTagName('video');
  for (var i = 0; i < videos.length; i++) {
    var v = videos[i];
    if (v.src && v.src.trim() !== '') {
      var type = v.src.includes('.m3u8') ? 'HLS Stream' : (v.src.includes('.mpd') ? 'DASH Stream' : 'Video Stream');
      sources.push({ src: v.src, label: type });
    }
    var childSources = v.getElementsByTagName('source');
    for (var j = 0; j < childSources.length; j++) {
      var s = childSources[j];
      if (s.src && s.src.trim() !== '') {
        var stype = s.src.includes('.m3u8') ? 'HLS Source' : (s.src.includes('.mpd') ? 'DASH Source' : (s.getAttribute('label') || 'Source ' + (j + 1)));
        sources.push({ src: s.src, label: stype });
      }
    }
    var poster = v.getAttribute('poster');
    if (poster && poster.trim() !== '') {
      sources.push({ src: poster, label: 'Video Poster Image' });
    }
  }
  var audios = document.getElementsByTagName('audio');
  for (var i = 0; i < audios.length; i++) {
    var a = audios[i];
    if (a.src && a.src.trim() !== '') {
      sources.push({ src: a.src, label: 'Audio Stream' });
    }
  }
  var lazyVideos = document.querySelectorAll('[data-src],[data-video-src]');
  for (var i = 0; i < lazyVideos.length; i++) {
    var src = lazyVideos[i].getAttribute('data-src') || lazyVideos[i].getAttribute('data-video-src');
    if (src && src.trim() !== '' && (src.includes('.mp4') || src.includes('.webm') || src.includes('.m3u8') || src.includes('.mpd'))) {
      var label = src.includes('.m3u8') ? 'HLS Stream (Lazy)' : (src.includes('.mpd') ? 'DASH Stream (Lazy)' : 'Lazy Video');
      sources.push({ src: src, label: label });
    }
  }
  var iframes = document.getElementsByTagName('iframe');
  for (var i = 0; i < iframes.length; i++) {
    var src = iframes[i].src;
    if (src && src.trim() !== '') {
      if (src.includes('youtube.com/embed/') || src.includes('player.vimeo.com/video/') || src.includes('.mp4') || src.includes('.m3u8') || src.includes('.mpd')) {
        sources.push({ src: src, label: 'Embedded Media' });
      }
    }
  }
  try {
    var resources = window.performance.getEntriesByType('resource');
    var maxEntries = Math.min(resources.length, 200);
    for (var r = 0; r < maxEntries; r++) {
      var rUrl = resources[r].name;
      if (rUrl && (rUrl.includes('.m3u8') || rUrl.includes('.mpd') || rUrl.includes('.m4s'))) {
        var label = rUrl.includes('.m3u8') ? 'HLS Manifest (Network)' : (rUrl.includes('.mpd') ? 'DASH Manifest (Network)' : 'DASH Segment');
        sources.push({ src: rUrl, label: label });
      }
    }
  } catch(e) {}
  return JSON.stringify(sources);
})();
''').catchError((_) => null).timeout(const Duration(seconds: 8));
      if (!isActive() || !containsTab(tab)) return;
      if (result is String && result.isNotEmpty && result != 'null') {
        var cleanResult = result;
        if (cleanResult.startsWith('"') && cleanResult.endsWith('"')) {
          try {
            cleanResult = jsonDecode(cleanResult);
          } catch (e, st) {
            Logger('media_sniffer')
                .warning('[media_sniffer] operation failed', e, st);
            if (cleanResult.length > 2) {
              cleanResult = cleanResult.substring(1, cleanResult.length - 1);
            }
          }
        }
        final List<dynamic> parsed = jsonDecode(cleanResult);
        final safeSources = parsed
            .where((e) {
              final src = (e as Map)['src'] as String? ?? '';
              final uri = Uri.tryParse(src);
              return uri != null &&
                  (uri.scheme == 'http' || uri.scheme == 'https') &&
                  uri.host.isNotEmpty;
            })
            .map((e) => e as Map)
            .toList();
        if (safeSources.isNotEmpty) {
          _update(() {
            detectedMediaSources[tab.id] =
                safeSources.map((e) => Map<String, dynamic>.from(e)).toList();
            if (detectedDownloadUrls[tab.id] == null) {
              detectedDownloadUrls[tab.id] = safeSources.first['src'] as String;
            }
          });
        }
      }
    } on TimeoutException {
      _log.warning(
          '[DMX Browser] Media scan JS injection timed out for tab ${tab.id}');
      if (isActive() && containsTab(tab)) {
        _update(() {
          mediaScanFailed[tab.id] = true;
        });
      }
    } catch (e) {
      if (e is MissingPluginException) return;
      _log.warning('[DMX Browser] Failed to run media scan JavaScript: $e');
      if (isActive() && containsTab(tab)) {
        _update(() {
          mediaScanFailed[tab.id] = true;
        });
      }
    }
  }
}
