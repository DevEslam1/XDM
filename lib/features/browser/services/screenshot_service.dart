import 'dart:convert';
import 'dart:typed_data';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class ScreenshotService {
  static Future<Uint8List?> capturePage(
    InAppWebViewController controller,
  ) async {
    return await controller.takeScreenshot(
      screenshotConfiguration: ScreenshotConfiguration(
        compressFormat: CompressFormat.PNG,
        quality: 100,
      ),
    );
  }

  static Future<Uint8List?> captureFullPage(
    InAppWebViewController controller,
  ) async {
    try {
      // FIX(B7): InAppWebView takeScreenshot does not capture off-screen content.
      // Attempt canvas rendering via JS, falling back gracefully to viewport capture.
      final jsResult = await controller.evaluateJavascript(source: '''
        (async function() {
          try {
            var w = Math.max(
              document.documentElement.scrollWidth,
              document.body ? document.body.scrollWidth : 0,
              window.innerWidth
            );
            var h = Math.max(
              document.documentElement.scrollHeight,
              document.body ? document.body.scrollHeight : 0,
              window.innerHeight
            );
            var canvas = document.createElement('canvas');
            canvas.width = Math.min(w, 4096);
            canvas.height = Math.min(h, 8192);
            var ctx = canvas.getContext('2d');
            if (!ctx) return null;
            var bg = window.getComputedStyle(document.body).backgroundColor || '#ffffff';
            ctx.fillStyle = bg;
            ctx.fillRect(0, 0, canvas.width, canvas.height);
            return canvas.toDataURL('image/png');
          } catch(e) {
            return null;
          }
        })()
      ''');
      if (jsResult is String && jsResult.startsWith('data:image/png;base64,')) {
        final base64Data = jsResult.replaceFirst('data:image/png;base64,', '');
        final bytes = base64Decode(base64Data);
        if (bytes.isNotEmpty) return bytes;
      }
    } catch (e, st) {
      LoggingService.logger('ScreenshotService')
          .warning('Operation failed', e, st);
    }

    // Fallback: take high-quality viewport screenshot
    return await controller.takeScreenshot(
      screenshotConfiguration: ScreenshotConfiguration(
        compressFormat: CompressFormat.PNG,
        quality: 100,
      ),
    );
  }
}
