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
        if (!_initialized)
          return; // If disposed before future resolves, skip processing
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
    // Do NOT reset _initialMediaConsumed here. If dispose is called before
    // getInitialMedia() resolves, we want it to be processed on the next init.
    // However, if it was already consumed, we mark it false so it can be fetched
    // again if the app is fully restarted in memory.
    // Actually, getInitialMedia only returns the initial media that caused the app launch.
    // If it's consumed once, it shouldn't be consumed again in the same session.
    // So we only reset it if it wasn't consumed yet.
    _lastReceivedUrl = null;
  }

  bool get isInitialized => _initialized;
}
