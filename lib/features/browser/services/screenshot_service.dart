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
    try {
      final res = await controller.evaluateJavascript(source: '''
        Math.max(
          document.body ? document.body.scrollHeight : 0,
          document.body ? document.body.offsetHeight : 0,
          document.documentElement ? document.documentElement.clientHeight : 0,
          document.documentElement ? document.documentElement.scrollHeight : 0,
          document.documentElement ? document.documentElement.offsetHeight : 0
        )
      ''');
      if (res is num) {
        snapshotHeight = res.toInt();
      } else if (res is String) {
        snapshotHeight = int.tryParse(res);
      }
    } catch (e, st) {
      LoggingService.logger('ScreenshotService')
          .warning('Operation failed', e, st);
    }

    return await controller.takeScreenshot(
      screenshotConfiguration: ScreenshotConfiguration(
        compressFormat: CompressFormat.PNG,
        quality: 100,
        rect: snapshotHeight != null
            ? InAppWebViewRect(
                x: 0,
                y: 0,
                width: 0,
                height: snapshotHeight.toDouble(),
              )
            : null,
      ),
    );
  }
}
