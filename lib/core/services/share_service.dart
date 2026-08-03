import 'dart:async';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'logging_service.dart';
import '../utils/url_utils.dart';

final _log = LoggingService.logger('ShareService');

/// Tracks recent URL shares for deduplication.
class _ShareEntry {
  final String url;
  final String source; // 'media_stream' or 'initial_media'
  final DateTime timestamp;

  const _ShareEntry({
    required this.url,
    required this.source,
    required this.timestamp,
  });

  bool isDuplicate(String otherUrl, String otherSource, Duration window) =>
      url == otherUrl &&
      source == otherSource &&
      DateTime.now().difference(timestamp) < window;
}

class ShareService {
  static final ShareService _instance = ShareService._internal();
  factory ShareService() => _instance;
  ShareService._internal();

  StreamSubscription? _intentSub;
  bool _initialized = false;
  int _generation = 0;
  bool _initialMediaConsumed = false;

  /// Tracks recent shares by URL + source for dedup without permanent suppression.
  final List<_ShareEntry> _recentShares = [];
  static const Duration _dedupWindow = Duration(seconds: 2);

  void init({
    required void Function(String url, {bool isInitial}) onUrlReceived,
  }) {
    dispose();

    void handleUrl(String? raw,
        {required String source, bool isInitial = false}) {
      final text = (raw ?? '').trim();
      if (text.isEmpty) return;

      final extractedUrl = extractUrlFromText(text) ?? text;

      if (!isHttpUrl(extractedUrl) &&
          !isMagnetUrl(extractedUrl) &&
          !isTorrentFileUrl(extractedUrl)) {
        return;
      }

      // Dedup: same URL + same source within the dedup window is suppressed.
      // Different source or outside the window is allowed through.
      final isDuplicate = _recentShares.any(
        (entry) => entry.isDuplicate(extractedUrl, source, _dedupWindow),
      );

      if (isDuplicate) {
        _log.fine('Deduped share: $extractedUrl from $source');
        return;
      }

      // Prune old entries
      _recentShares.removeWhere(
        (entry) => DateTime.now().difference(entry.timestamp) > _dedupWindow,
      );

      _recentShares.add(
        _ShareEntry(
            url: extractedUrl, source: source, timestamp: DateTime.now()),
      );

      onUrlReceived(extractedUrl, isInitial: isInitial);
    }

    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (value) {
        for (final file in value) {
          handleUrl(file.path, source: 'media_stream', isInitial: false);
        }
      },
      onError: (err) {
        _log.warning('getMediaStream error', err);
      },
    );

    final gen = ++_generation;

    if (!_initialMediaConsumed) {
      ReceiveSharingIntent.instance.getInitialMedia().then((value) {
        if (gen != _generation) return;
        for (final file in value) {
          handleUrl(file.path, source: 'initial_media', isInitial: true);
        }
        _initialMediaConsumed = true;
      });
    }
    _initialized = true;
  }

  void dispose() {
    _intentSub?.cancel();
    _intentSub = null;
    _initialized = false;
    _recentShares.clear();
  }

  bool get isInitialized => _initialized;
}
