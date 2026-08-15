import 'dart:io';
import 'dart:typed_data';

import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String testFilePath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pfw_test_');
    testFilePath = '${tempDir.path}/test_file.bin';
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('PositionalFileWriter', () {
    test('Concurrent writes from multiple chunks produce correct data',
        () async {
      const totalSize = 1000;
      const threadCount = 4;
      final writer = await PositionalFileWriter.open(
        testFilePath,
        totalSize: totalSize,
        threadCount: threadCount,
        bufferSize: 64,
      );

      final chunk0Data = Uint8List.fromList(List.generate(250, (i) => 1));
      final chunk1Data = Uint8List.fromList(List.generate(250, (i) => 2));
      final chunk2Data = Uint8List.fromList(List.generate(250, (i) => 3));
      final chunk3Data = Uint8List.fromList(List.generate(250, (i) => 4));

      await Future.wait([
        writer.write(0, 0, chunk0Data),
        writer.write(1, 250, chunk1Data),
        writer.write(2, 500, chunk2Data),
        writer.write(3, 750, chunk3Data),
      ]);

      await writer.flushAll();
      final read0 = await writer.readRange(0, 250);
      final read1 = await writer.readRange(250, 250);
      final read2 = await writer.readRange(500, 250);
      final read3 = await writer.readRange(750, 250);

      expect(read0, equals(chunk0Data));
      expect(read1, equals(chunk1Data));
      expect(read2, equals(chunk2Data));
      expect(read3, equals(chunk3Data));

      await writer.close();
    });

    test('Resume from partial file validates bounds', () async {
      const initialSize = 500;
      final initialWriter = await PositionalFileWriter.open(
        testFilePath,
        totalSize: initialSize,
        threadCount: 2,
      );
      await initialWriter.write(
          0, 0, Uint8List.fromList(List.generate(250, (i) => 42)));
      await initialWriter.flushAll();
      await initialWriter.close();

      final resumeWriter = await PositionalFileWriter.openForResume(
        testFilePath,
        threadCount: 2,
        totalSize: 1000,
      );

      expect(await resumeWriter.length(), equals(1000));
      final readPart = await resumeWriter.readRange(0, 250);
      expect(
          readPart, equals(Uint8List.fromList(List.generate(250, (i) => 42))));

      await resumeWriter.write(
          1, 500, Uint8List.fromList(List.generate(250, (i) => 99)));
      await resumeWriter.flushAll();
      final readSecond = await resumeWriter.readRange(500, 250);
      expect(readSecond,
          equals(Uint8List.fromList(List.generate(250, (i) => 99))));

      await resumeWriter.close();
    });

    test('Write beyond declared size throws PositionalFileWriterException',
        () async {
      const totalSize = 100;
      final writer = await PositionalFileWriter.open(
        testFilePath,
        totalSize: totalSize,
        threadCount: 1,
      );

      final invalidData = Uint8List(50);
      expect(
        () => writer.write(0, 80, invalidData),
        throwsA(isA<PositionalFileWriterException>()),
      );

      await writer.close();
    });

    test('Close and reopen lifecycle works', () async {
      final writer = await PositionalFileWriter.open(
        testFilePath,
        totalSize: 200,
        threadCount: 1,
      );
      await writer.write(0, 0, Uint8List.fromList([10, 20, 30]));
      await writer.close();

      expect(
        () => writer.write(0, 0, Uint8List.fromList([1])),
        throwsA(isA<PositionalFileWriterException>()),
      );

      final reopened = await PositionalFileWriter.openForResume(
        testFilePath,
        threadCount: 1,
        totalSize: 200,
      );
      final data = await reopened.readRange(0, 3);
      expect(data, equals(Uint8List.fromList([10, 20, 30])));
      await reopened.close();
    });

    test('Flush flushes buffers to disk', () async {
      final writer = await PositionalFileWriter.open(
        testFilePath,
        totalSize: 500,
        threadCount: 1,
        bufferSize: 1024,
      );

      await writer.write(0, 0, Uint8List.fromList([1, 2, 3, 4, 5]));
      await writer.flush(0);

      final readData = await writer.readRange(0, 5);
      expect(readData, equals(Uint8List.fromList([1, 2, 3, 4, 5])));

      await writer.close();
    });

    test('Buffer overflow flushes automatically', () async {
      final writer = await PositionalFileWriter.open(
        testFilePath,
        totalSize: 100,
        threadCount: 1,
        bufferSize: 10,
      );

      final data = Uint8List.fromList(List.generate(15, (i) => i));
      await writer.write(0, 0, data);

      final readData = await writer.readRange(0, 15);
      expect(readData, equals(data));

      await writer.close();
    });
  });
}
