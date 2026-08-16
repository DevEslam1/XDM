import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';

class PictureInPictureService {
  static final _log = Logger('PictureInPictureService');

  static Future<bool> isSupported(InAppWebViewController controller) async {
    try {
      final result = await controller.evaluateJavascript(
        source: 'document.pictureInPictureEnabled === true;',
      );
      return result == true || result == 'true';
    } catch (e, st) {
      LoggingService.logger('PictureInPictureService')
          .warning('Operation failed with fallback', e, st);
      return false;
    }
  }

  static Future<bool> enterPiP(InAppWebViewController controller) async {
    try {
      final supported = await isSupported(controller);
      if (!supported) return false;
      await controller.evaluateJavascript(source: '''
        (function() {
          const video = document.querySelector('video');
          if (video && video.requestPictureInPicture) {
            video.requestPictureInPicture();
          }
        })();
      ''');
      return true;
    } catch (e, st) {
      _log.warning('enterPiP failed', e, st);
      return false;
    }
  }

  static Future<bool> exitPiP(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(source: '''
        (function() {
          if (document.pictureInPictureElement) {
            document.exitPictureInPicture();
          }
        })();
      ''');
      return true;
    } catch (e, st) {
      _log.warning('exitPiP failed', e, st);
      return false;
    }
  }
}
