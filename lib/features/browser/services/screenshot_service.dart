import 'dart:convert';
import 'dart:typed_data';

import 'package:dmx/core/services/logging_service.dart';
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
    int? snapshotHeight;
    int? viewportWidth;
    try {
      final res = await controller.evaluateJavascript(source: '''
        (function() {
          var w = document.documentElement.clientWidth || window.innerWidth || 400;
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
          .warning('Operation failed', e, st);
    }

    // FIX(B8): Use the real viewport width instead of width: 0 so the captured
    // rect spans the full page width; without it some engines clip the shot.
    return await controller.takeScreenshot(
      screenshotConfiguration: ScreenshotConfiguration(
        compressFormat: CompressFormat.PNG,
        quality: 100,
        rect: snapshotHeight != null
            ? InAppWebViewRect(
                x: 0,
                y: 0,
                width: (viewportWidth ?? 400).toDouble(),
                height: snapshotHeight.toDouble(),
              )
            : null,
      ),
    );
  }
}
