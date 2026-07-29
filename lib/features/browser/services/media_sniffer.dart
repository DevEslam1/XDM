import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/services/youtube_service.dart';
import '../models/browser_tab.dart';

/// Detects downloadable media on browser pages (REFACTOR B extraction from
/// `_BrowserScreenState`).
///
/// Owns all per-tab detection state and runs the media-scan JavaScript on the
/// tab's WebView. It does NOT manage UI: the host screen listens through
/// [onStateChanged] and renders FABs/sheets from the exposed maps.
class MediaSniffer {
  MediaSniffer({
    required this.isActive,
    required this.containsTab,
    required this.isSnifferEnabled,
    required this.onStateChanged,
  });

  /// Whether the host screen is still mounted.
  final bool Function() isActive;

  /// Whether [tab] is still one of the open tabs.
  final bool Function(BrowserTab tab) containsTab;

  /// Whether the media sniffer toggle is enabled.
  final bool Function() isSnifferEnabled;

  /// Notifies the host that detection state changed (triggers setState).
  final VoidCallback onStateChanged;

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
    onStateChanged();
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
    // Evict expired entries older than 10 minutes
    final now = DateTime.now();
    ytDetectionFailed.removeWhere(
      (url, timestamp) =>
          now.difference(timestamp) > const Duration(minutes: 10),
    );
  }

  /// Cancels all pending scan timers and clears detection state.
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
        final info = await YoutubeService.getPlaylistInfo(scannedUrl);
        if (info != null && isActive() && tab.url == scannedUrl) {
          final count = info['videoCount'] as int? ?? 0;
          _update(() {
            detectedPlaylistUrls[tab.id] = count;
            detectedDownloadUrls[tab.id] = scannedUrl;
          });
        }
      } catch (e) {
        debugPrint('YouTube playlist scan error: $e');
      }
      if (YoutubeService.isYoutubeVideoUrl(scannedUrl)) {
        try {
          final youtubeStreams = await YoutubeService.getStreams(scannedUrl);
          if (youtubeStreams.isNotEmpty &&
              isActive() &&
              tab.url == scannedUrl) {
            _update(() {
              detectedMediaSources[tab.id] = youtubeStreams;
            });
          }
        } catch (e) {
          debugPrint('YouTube single stream scan error after playlist: $e');
        }
      }
      return;
    }
    if (YoutubeService.isYoutubeVideoUrl(scannedUrl)) {
      try {
        final youtubeStreams = await YoutubeService.getStreams(scannedUrl);
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
        debugPrint('YouTube stream detection error: $e');
      }
      if (isActive() && tab.url == scannedUrl) {
        _update(() {
          ytDetectionFailed.remove(scannedUrl);
          if (ytDetectionFailed.length >= 200) {
            final oldestKey = ytDetectionFailed.entries
                .reduce((a, b) => a.value.isBefore(b.value) ? a : b)
                .key;
            ytDetectionFailed.remove(oldestKey);
          }
          ytDetectionFailed[scannedUrl] = DateTime.now();
        });
      }
    }
    try {
      final result = await tab.controller.runJavaScriptReturningResult('''
(function() {
  var sources = [];
  var videos = document.getElementsByTagName('video');
  for (var i = 0; i < videos.length; i++) {
    var v = videos[i];
    if (v.src && v.src.trim() !== '' && !v.src.startsWith('blob:')) {
      sources.push({ src: v.src, label: 'Video Stream (Default)' });
    }
    var childSources = v.getElementsByTagName('source');
    for (var j = 0; j < childSources.length; j++) {
      var s = childSources[j];
      if (s.src && s.src.trim() !== '' && !s.src.startsWith('blob:')) {
        var label = s.getAttribute('label') || s.getAttribute('res') || s.getAttribute('type') || ('Resolution ' + (j + 1));
        sources.push({ src: s.src, label: label });
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
    if (a.src && a.src.trim() !== '' && !a.src.startsWith('blob:')) {
      sources.push({ src: a.src, label: 'Audio Stream' });
    }
  }
  var lazyVideos = document.querySelectorAll('[data-src],[data-video-src]');
  for (var i = 0; i < lazyVideos.length; i++) {
    var src = lazyVideos[i].getAttribute('data-src') || lazyVideos[i].getAttribute('data-video-src');
    if (src && src.trim() !== '' && !src.startsWith('blob:') && (src.includes('.mp4') || src.includes('.webm') || src.includes('.m3u8'))) {
      sources.push({ src: src, label: 'Lazy-Loaded Video' });
    }
  }
  var iframes = document.getElementsByTagName('iframe');
  for (var i = 0; i < iframes.length; i++) {
    var src = iframes[i].src;
    if (src && src.trim() !== '') {
      if (src.includes('youtube.com/embed/') || src.includes('player.vimeo.com/video/') || src.includes('.mp4') || src.includes('.m3u8')) {
        sources.push({ src: src, label: 'Embedded Video' });
      }
    }
  }
  return JSON.stringify(sources);
})();
''');
      if (result is String && result.isNotEmpty && result != 'null') {
        var cleanResult = result;
        if (cleanResult.startsWith('"') && cleanResult.endsWith('"')) {
          try {
            cleanResult = jsonDecode(cleanResult);
          } catch (_) {
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
            detectedMediaSources[tab.id] = safeSources
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
            if (detectedDownloadUrls[tab.id] == null) {
              detectedDownloadUrls[tab.id] = safeSources.first['src'] as String;
            }
          });
        }
      }
    } catch (e) {
      debugPrint('[DMX Browser] Failed to run media scan JavaScript: $e');
      _update(() {
        mediaScanFailed[tab.id] = true;
      });
    }
  }
}
