import 'package:dmx/core/services/download_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadEngine Path Traversal Security Checks (L11)', () {
    test('blocks ../etc/passwd traversal attempt', () async {
      expect(
        () => DownloadEngine.validateSavePath('../etc/passwd'),
        throwsA(isA<InvalidPathException>()),
      );
    });

    test('blocks a/../../b traversal attempt', () async {
      expect(
        () => DownloadEngine.validateSavePath('a/../../b'),
        throwsA(isA<InvalidPathException>()),
      );
    });

    test('allows .../file triple-dot legal path without InvalidPathException',
        () async {
      // Must not throw InvalidPathException (literal triple-dot is legal naming)
      try {
        await DownloadEngine.validateSavePath('.../file');
      } catch (e) {
        expect(e, isNot(isA<InvalidPathException>()));
      }
    });

    test('blocks folder/./file suspicious current directory relative segment',
        () async {
      expect(
        () => DownloadEngine.validateSavePath('folder/./file'),
        throwsA(isA<InvalidPathException>()),
      );
    });
  });
}
