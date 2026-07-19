import 'dart:async';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import '../utils/url_utils.dart';

class ShareService {
  static final ShareService _instance = ShareService._internal();
  factory ShareService() => _instance;
  ShareService._internal();

  StreamSubscription? _intentSub;
  bool _initialized = false;
  static bool _initialMediaConsumed = false;
  String? _lastReceivedUrl;

  void init({required void Function(String url) onUrlReceived}) {
    dispose();

    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((value) {
      for (final file in value) {
        final trimmed = file.path.trim();
        if (isHttpUrl(trimmed) && trimmed != _lastReceivedUrl) {
          _lastReceivedUrl = trimmed;
          onUrlReceived(trimmed);
        }
      }
    }, onError: (err) {
    });

    if (!_initialMediaConsumed) {
      _initialMediaConsumed = true;
      ReceiveSharingIntent.instance.getInitialMedia().then((value) {
        if (!_initialized) return;
        for (final file in value) {
          final trimmed = file.path.trim();
          if (isHttpUrl(trimmed) && trimmed != _lastReceivedUrl) {
            _lastReceivedUrl = trimmed;
            onUrlReceived(trimmed);
          }
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
