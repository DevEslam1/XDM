import 'dart:async';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import '../utils/url_utils.dart';

class ShareService {
  static final ShareService _instance = ShareService._internal();
  factory ShareService() => _instance;
  ShareService._internal();

  StreamSubscription? _intentSub;
  bool _initialized = false;
  bool _initialMediaConsumed = false;
  String? _lastReceivedUrl;

  void init({required void Function(String url, {bool isInitial}) onUrlReceived}) {
    dispose();

    void handleUrl(String? raw, {bool isInitial = false}) {
      final text = (raw ?? '').trim();
      if (text.isEmpty) return;

      // Extract URL from shared text (apps like TikTok/X/FB share text like "Check out this video: https://...")
      final extractedUrl = extractUrlFromText(text) ?? text;

      if ((isHttpUrl(extractedUrl) ||
              isMagnetUrl(extractedUrl) ||
              isTorrentFileUrl(extractedUrl)) &&
          extractedUrl != _lastReceivedUrl) {
        _lastReceivedUrl = extractedUrl;
        onUrlReceived(extractedUrl, isInitial: isInitial);
        Timer(const Duration(seconds: 2), () {
          if (_lastReceivedUrl == extractedUrl) {
            _lastReceivedUrl = null;
          }
        });
      }
    }

    // Shared links/URLs arrive as SharedMediaFile entries where the value is
    // carried in `path` (type text/url/file). Handle all of them so shared
    // URL text isn't silently dropped.
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((value) {
      for (final file in value) {
        handleUrl(file.path, isInitial: false);
      }
    }, onError: (err) {
    });

    if (!_initialMediaConsumed) {
      ReceiveSharingIntent.instance.getInitialMedia().then((value) {
        _initialMediaConsumed = true; // Set AFTER processing
        if (!_initialized) return;
        for (final file in value) {
          handleUrl(file.path, isInitial: true);
        }
      });
    }
    _initialized = true;
  }

  void dispose() {
    _intentSub?.cancel();
    _intentSub = null;
    _initialized = false;
    _lastReceivedUrl = null;
  }

  bool get isInitialized => _initialized;
}
