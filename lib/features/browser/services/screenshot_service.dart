import 'package:dmx/core/services/logging_service.dart';
import 'dart:typed_data';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class ScreenshotService {
  static Future<Uint8List?> capturePage(
    InAppWebViewController controller,
  ) async {
    return await controller.takeScreenshot();
  }

  static Future<Uint8List?> captureFullPage(
    InAppWebViewController controller,
  ) async {
    try {
      await controller.evaluateJavascript(source: '''
        Math.max(
          document.body.scrollHeight,
          document.body.offsetHeight,
          document.documentElement.clientHeight,
          document.documentElement.scrollHeight,
          document.documentElement.offsetHeight
        )
      ''');
    } catch (e, st) {
      LoggingService.logger('ScreenshotService').warning('Operation failed', e, st);
    }

    return await controller.takeScreenshot(
      screenshotConfiguration: ScreenshotConfiguration(
        compressFormat: CompressFormat.PNG,
        quality: 100,
      ),
    );
  }
}
