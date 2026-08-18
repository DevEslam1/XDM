import 'dart:convert';
import 'dart:typed_data';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class ScreenshotService {
  static Future<Uint8List?> capturePage(
    InAppWebViewController controller,
  ) async {
    try {
      final res = await controller.evaluateJavascript(source: '''
        (function() {
          var w = window.innerWidth || document.documentElement.clientWidth || 0;
          var h = window.innerHeight || document.documentElement.clientHeight || 0;
          return (w > 0 && h > 0);
        })()
      ''');
      if (res == true || res == 'true' || res == 1) {
        return await controller.takeScreenshot();
      }
    } catch (e) {
      LoggingService.logger('ScreenshotService')
          .fine('Skipping screenshot: WebView dimensions are 0 or not ready ($e).');
    }
    return null;
  }

  static Future<Uint8List?> captureFullPage(
    InAppWebViewController controller,
  ) async {
    try {
      int? snapshotHeight;
      int? viewportWidth;
      try {
        final res = await controller.evaluateJavascript(source: '''
          (function() {
            var w = document.documentElement.clientWidth || window.innerWidth || 0;
            var h = Math.max(
              document.body ? document.body.scrollHeight : 0,
              document.body ? document.body.offsetHeight : 0,
              document.documentElement ? document.documentElement.clientHeight : 0,
              document.documentElement ? document.documentElement.scrollHeight : 0,
              document.documentElement ? document.documentElement.offsetHeight : 0
            );
            return JSON.stringify({ width: w, height: h });
          })()
        ''');
        if (res is String) {
          final data = jsonDecode(res) as Map<String, dynamic>;
          viewportWidth = (data['width'] as num?)?.toInt();
          snapshotHeight = (data['height'] as num?)?.toInt();
        }
      } catch (e, st) {
        LoggingService.logger('ScreenshotService')
            .fine('evaluateJavascript for full page dimensions failed', e, st);
      }

      if (viewportWidth == null ||
          viewportWidth <= 0 ||
          snapshotHeight == null ||
          snapshotHeight <= 0) {
        return null;
      }

      return await controller.takeScreenshot(
        screenshotConfiguration: ScreenshotConfiguration(
          compressFormat: CompressFormat.PNG,
          quality: 100,
          rect: InAppWebViewRect(
            x: 0,
            y: 0,
            width: viewportWidth.toDouble(),
            height: snapshotHeight.toDouble(),
          ),
        ),
      );
    } catch (e, st) {
      LoggingService.logger('ScreenshotService')
          .warning('captureFullPage failed', e, st);
      return null;
    }
  }
}
