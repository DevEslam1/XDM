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

  void init({required void Function(String url) onUrlReceived}) {
    dispose();

    void handleUrl(String? raw) {
      final trimmed = (raw ?? '').trim();
      if (isHttpUrl(trimmed) && trimmed != _lastReceivedUrl) {
        _lastReceivedUrl = trimmed;
        onUrlReceived(trimmed);
      }
    }

    // Shared links/URLs arrive as SharedMediaFile entries where the value is
    // carried in `path` (type text/url/file). Handle all of them so shared
    // URL text isn't silently dropped.
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((value) {
      for (final file in value) {
        final type = file.type;
        if (type == SharedMediaType.text ||
            type == SharedMediaType.url ||
            type == SharedMediaType.file) {
          handleUrl(file.path);
        } else {
          handleUrl(file.path);
        }
      }
    }, onError: (err) {
    });

    if (!_initialMediaConsumed) {
      _initialMediaConsumed = true;
      ReceiveSharingIntent.instance.getInitialMedia().then((value) {
        if (!_initialized) return;
        for (final file in value) {
          handleUrl(file.path);
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
