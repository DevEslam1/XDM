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

  void init({
    required void Function(String url, {bool isInitial}) onUrlReceived,
  }) {
    dispose();

    void handleUrl(String? raw, {bool isInitial = false}) {
      final text = (raw ?? '').trim();
      if (text.isEmpty) return;

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

    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((value) {
      for (final file in value) {
        handleUrl(file.path, isInitial: false);
      }
    }, onError: (err) {});

    if (!_initialMediaConsumed) {
      ReceiveSharingIntent.instance.getInitialMedia().then((value) {
        if (!_initialized) {
          return; // If disposed before future resolves, skip processing
        }
        for (final file in value) {
          handleUrl(file.path, isInitial: true);
        }
        _initialMediaConsumed =
            true; // Mark consumed only after successful processing
      });
    }
    _initialized = true;
  }

  void dispose() {
    _intentSub?.cancel();
    _intentSub = null;
    _initialized = false;
    // Note: _initialMediaConsumed is intentionally NOT reset here.
    // getInitialMedia() only returns the media that launched the app.
    // Once consumed, it should not be re-processed in the same session.
    _lastReceivedUrl = null;
  }

  bool get isInitialized => _initialized;
}
