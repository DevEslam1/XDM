import 'dart:async';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import '../utils/url_utils.dart';

class ShareService {
  static final ShareService _instance = ShareService._internal();
  factory ShareService() => _instance;
  ShareService._internal();

  StreamSubscription? _intentSub;

  /// Initializes listening to sharing intents.
  /// When a valid HTTP/HTTPS URL is received, it triggers [onUrlReceived].
  void init({required void Function(String url) onUrlReceived}) {
    // Listen to shared media streams (when app is in background/foreground)
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((files) {
      for (final file in files) {
        final text = file.path.trim();
        if (isHttpUrl(text)) {
          onUrlReceived(text);
          break;
        }
      }
    }, onError: (err) {
      // Handle or ignore errors
    });

    // Handle shared media on initial app launch (when app was closed)
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      for (final file in files) {
        final text = file.path.trim();
        if (isHttpUrl(text)) {
          onUrlReceived(text);
          break;
        }
      }
    });
  }

  void dispose() {
    _intentSub?.cancel();
  }
}
