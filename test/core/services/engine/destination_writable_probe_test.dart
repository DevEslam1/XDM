import 'dart:io';

import 'package:dmx/core/services/permission_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// F27: the destination writability probe must pass on a writable folder and
/// must not false-positive; permission-class failures must report false.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('f27_writable_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('isDirectoryWritable returns null off-Android (defer to real writes)',
      () async {
    // On the test host (Windows/Linux/macOS) the probe is a no-op.
    final result = await PermissionService().isDirectoryWritable(tempDir.path);
    if (Platform.isAndroid) {
      expect(result, isNot(false));
    } else {
      expect(result, isNull);
    }
  });

  test('a writable existing folder leaves no probe residue', () async {
    await PermissionService().isDirectoryWritable(tempDir.path);
    final leftovers = tempDir
        .listSync()
        .where((e) => e.path.contains('.dmx_write_probe'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('empty path is inconclusive (null)', () async {
    expect(await PermissionService().isDirectoryWritable(''), isNull);
  });
}
