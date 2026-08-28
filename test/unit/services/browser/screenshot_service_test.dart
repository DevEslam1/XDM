import 'dart:typed_data';
import 'package:dmx/features/browser/services/screenshot_service.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockWebViewController implements InAppWebViewController {
  Uint8List? screenshotBytes;
  Object? jsResult;

  @override
  Future<Uint8List?> takeScreenshot({
    ScreenshotConfiguration? screenshotConfiguration,
  }) async {
    return screenshotBytes;
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    return jsResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('ScreenshotService Tests [Browser 10/10]', () {
    late _MockWebViewController mockController;

    setUp(() {
      mockController = _MockWebViewController();
    });

    test('capturePage calls takeScreenshot and returns bytes', () async {
      final sample = Uint8List.fromList([1, 2, 3, 4]);
      mockController.screenshotBytes = sample;

      final result = await ScreenshotService.capturePage(mockController);
      expect(result, equals(sample));
    });

    test('captureFullPage falls back to takeScreenshot when JS returns null',
        () async {
      mockController.jsResult = null;
      final sample = Uint8List.fromList([5, 6, 7]);
      mockController.screenshotBytes = sample;

      final result = await ScreenshotService.captureFullPage(mockController);
      expect(result, equals(sample));
    });
  });
}
