import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class PictureInPictureService {
  static Future<void> enterPiP(InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: '''
      (function() {
        const video = document.querySelector('video');
        if (video && video.requestPictureInPicture) {
          video.requestPictureInPicture();
        }
      })();
    ''');
  }

  static Future<void> exitPiP(InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: '''
      (function() {
        if (document.pictureInPictureElement) {
          document.exitPictureInPicture();
        }
      })();
    ''');
  }
}
