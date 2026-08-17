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
      final res = await controller.evaluateJavascript(source: '''
        (async function() {
          try {
            const video = document.querySelector('video');
            if (video && typeof video.requestPictureInPicture === 'function') {
              await video.requestPictureInPicture();
              return true;
            }
            return false;
          } catch (e) {
            return false;
          }
        })();
      ''');
      return res == true || res == 'true';
    } catch (e, st) {
      _log.warning('enterPiP failed', e, st);
      return false;
    }
  }

  static Future<bool> exitPiP(InAppWebViewController controller) async {
    try {
      final res = await controller.evaluateJavascript(source: '''
        (async function() {
          try {
            if (document.pictureInPictureElement && typeof document.exitPictureInPicture === 'function') {
              await document.exitPictureInPicture();
              return true;
            }
            return false;
          } catch (e) {
            return false;
          }
        })();
      ''');
      return res == true || res == 'true';
    } catch (e, st) {
      _log.warning('exitPiP failed', e, st);
      return false;
    }
  }
}
