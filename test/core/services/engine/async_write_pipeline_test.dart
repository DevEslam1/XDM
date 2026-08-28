import 'dart:io';
import 'dart:typed_data';

import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AsyncWritePipeline Tests', () {
    late Directory tempDir;
    late File testFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pipeline_test_');
      testFile = File('${tempDir.path}/test_output.bin');
    });

    tearDown(() async {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('AsyncWritePipeline enqueues and flushes batches properly', () async {
      final raf = await testFile.open(mode: FileMode.write);
      final pipeline = AsyncWritePipeline(raf, maxQueueBytes: 1024 * 1024);

      final data1 = Uint8List.fromList([1, 2, 3, 4]);
      final data2 = Uint8List.fromList([5, 6, 7, 8]);

      await pipeline.enqueue(0, data1);
      await pipeline.enqueue(4, data2);

      await pipeline.flush();
      await pipeline.close();

      final bytes = await testFile.readAsBytes();
      expect(bytes, [1, 2, 3, 4, 5, 6, 7, 8]);
    });
  });
}
