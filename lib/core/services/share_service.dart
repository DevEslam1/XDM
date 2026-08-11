import 'dart:async';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'logging_service.dart';
import '../utils/url_utils.dart';

final _log = LoggingService.logger('ShareService');

class _ShareEntry {
  final String url;
  final String source;
  final DateTime timestamp;
  const _ShareEntry({
    required this.url,
    required this.source,
    required this.timestamp,
  });

  bool isDuplicate(String otherUrl, Duration window) =>
      url == otherUrl && DateTime.now().difference(timestamp) < window;
}

class ShareService {
  static final ShareService _instance = ShareService._internal();
  factory ShareService() => _instance;
  ShareService._internal();

  StreamSubscription? _intentSub;
  bool _initialized = false;
  int _generation = 0;
  bool _initialMediaConsumed = false;
  void Function(String url, {bool isInitial})? _onUrlReceived;

  final List<_ShareEntry> _recentShares = [];
  final List<DateTime> _arrivalTimestamps = [];
  static const Duration _dedupWindow = Duration(seconds: 2);
  static const int _maxQueueSize = 5;

  void init({
    required void Function(String url, {bool isInitial}) onUrlReceived,
  }) {
    dispose();
    _onUrlReceived = onUrlReceived;

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

  void handleUrl(
    String? raw, {
    required String source,
    bool isInitial = false,
  }) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return;

    final extractedUrl = extractUrlFromText(text) ?? text;
    if (!isHttpUrl(extractedUrl) &&
        !isMagnetUrl(extractedUrl) &&
        !isTorrentFileUrl(extractedUrl)) {
      _log.warning('Invalid scheme rejected: $extractedUrl');
      return;
    }

    final now = DateTime.now();
    _arrivalTimestamps.removeWhere(
      (ts) => now.difference(ts) > const Duration(minutes: 5),
    );
    final recentWindowCount = _arrivalTimestamps
        .where((ts) => now.difference(ts) <= const Duration(seconds: 1))
        .length;
    if (recentWindowCount >= _maxQueueSize) {
      _log.warning(
        'Share intent flood detected (>$_maxQueueSize in 1s). Dropping intent.',
      );
      return;
    }

    final isDuplicate = _recentShares.any(
      (entry) => entry.isDuplicate(extractedUrl, _dedupWindow),
    );
    if (isDuplicate) {
      _log.fine('Deduped share: $extractedUrl from $source');
      return;
    }

    _recentShares.removeWhere(
      (entry) => now.difference(entry.timestamp) > _dedupWindow,
    );
    _recentShares.add(
      _ShareEntry(
        url: extractedUrl,
        source: source,
        timestamp: now,
      ),
    );
    _arrivalTimestamps.add(now);

    _onUrlReceived?.call(extractedUrl, isInitial: isInitial);
  }

  void dispose() {
    _intentSub?.cancel();
    _intentSub = null;
    _initialized = false;
    _initialMediaConsumed = false;
    _onUrlReceived = null;
    _recentShares.clear();
    _arrivalTimestamps.clear();
  }

  bool get isInitialized => _initialized;
}