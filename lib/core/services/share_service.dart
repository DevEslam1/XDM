import 'dart:async';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import '../utils/url_utils.dart';

class ShareService {
  static final ShareService _instance = ShareService._internal();
  factory ShareService() => _instance;
  ShareService._internal();

  StreamSubscription? _intentSub;
  bool _initialized = false;

  /// Initializes listening to sharing intents.
  /// When a valid HTTP/HTTPS URL is received, it triggers [onUrlReceived].
  ///
  /// Safe to call multiple times: previous subscriptions are cancelled
  /// before a new one is set up so we don't leak listeners and double-fire
  /// [onUrlReceived].
  void init({required void Function(String url) onUrlReceived}) {
    dispose();

    // Listen to shared text/URL streams (when app is in background/foreground)
    _intentSub = ReceiveSharingIntent.instance.getTextStream().listen((text) {
      final trimmed = text.trim();
      if (isHttpUrl(trimmed)) {
        onUrlReceived(trimmed);
      }
    }, onError: (err) {
      // Handle or ignore errors
    });

    // Handle shared text/URL on initial app launch (when app was closed)
    ReceiveSharingIntent.instance.getInitialText().then((text) {
      if (text != null) {
        final trimmed = text.trim();
        if (isHttpUrl(trimmed)) {
          onUrlReceived(trimmed);
        }
      }
    });
    _initialized = true;
  }

  void dispose() {
    _intentSub?.cancel();
    _intentSub = null;
    _initialized = false;
  }

  bool get isInitialized => _initialized;
}
