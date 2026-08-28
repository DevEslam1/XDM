import 'package:dmx/features/browser/services/picture_in_picture_service.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeWebViewController implements InAppWebViewController {
  Object? evaluatedResult;
  bool throwOnEvaluate = false;

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (throwOnEvaluate) throw Exception('JS evaluation failure');
    return evaluatedResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('PictureInPictureService Tests [Browser 10/10]', () {
    late _FakeWebViewController fakeController;

    setUp(() {
      fakeController = _FakeWebViewController();
    });

    test(
        'isSupported returns true when document.pictureInPictureEnabled is true',
        () async {
      fakeController.evaluatedResult = true;
      final supported =
          await PictureInPictureService.isSupported(fakeController);
      expect(supported, isTrue);
    });

    test('isSupported returns false when evaluation throws or returns false',
        () async {
      fakeController.throwOnEvaluate = true;
      final supported =
          await PictureInPictureService.isSupported(fakeController);
      expect(supported, isFalse);
    });

    test('enterPiP returns true on successful requestPictureInPicture',
        () async {
      fakeController.evaluatedResult = true;
      final entered = await PictureInPictureService.enterPiP(fakeController);
      expect(entered, isTrue);
    });

    test('enterPiP returns false when PiP is not supported', () async {
      fakeController.evaluatedResult = false;
      final entered = await PictureInPictureService.enterPiP(fakeController);
      expect(entered, isFalse);
    });

    test('exitPiP returns true on successful exit', () async {
      fakeController.evaluatedResult = true;
      final exited = await PictureInPictureService.exitPiP(fakeController);
      expect(exited, isTrue);
    });
  });
}
