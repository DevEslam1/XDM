import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:dmx/core/services/engines/http_download_engine.dart';
import 'package:dmx/core/services/transfer_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/scriptable_http_server.dart';

/// F25 regression: the single-stream path keeps one raw [RandomAccessFile].
/// The unawaited durable state-save used to call `raf.flush()` (via
/// `preSaveFlush`) while the write loop was still calling `raf.writeFrom()`,
/// so once the ~2MB state-save threshold was crossed dart:io threw
/// `FileSystemException("An async operation is currently pending")` and the
/// download aborted with a bogus "File system error". The failure only
/// manifested on payloads larger than the 2MB save threshold, which is why a
/// multi-MB download is required here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ScriptableHttpServer server;
  late Uint8List payload;
  late String expectedSha256;
  const fileSize = 6 * 1024 * 1024;

  setUp(() async {
    HttpOverrides.global = null;
    tempDir = await Directory.systemTemp.createTemp('single_stream_raf_race_');
    payload = Uint8List.fromList(
      List.generate(fileSize, (i) => (i * 43 + 17) % 256),
    );
    expectedSha256 = sha256.convert(payload).toString();

    server = ScriptableHttpServer();
    await server.start();
    server.setPayload(payload, etag: '"f25"');
  });

  tearDown(() async {
    HttpTransferJob.hardTimeoutForTesting = null;
    await server.stop();
    // On the racing (broken) path the download leaves its handle open, so
    // tolerate a locked temp dir instead of masking the real assertion.
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } on FileSystemException {
      // ignored
    }
  });

  test(
      'F25: multi-MB single-stream download survives concurrent state-save flush',
      () async {
    final tempPath = '${tempDir.path}/f25.bin.tmp';
    final receivePort = ReceivePort();
    final job = HttpTransferJob(
      DownloadCommand(
        taskId: 'f25',
        url: server.urlFor('/f25.bin'),
        punyUrl: server.urlFor('/f25.bin'),
        localFilePath: '${tempDir.path}/f25.bin',
        tempFilePath: tempPath,
        knownFileSize: fileSize,
        threadCount: 1,
        supportsResume: true,
        resumeIntegrityCheck: false,
      ),
      receivePort.sendPort,
    );
    job.stateForTesting = TransferState(
      totalSize: fileSize,
      threadCount: 1,
      etag: '"f25"',
      chunks: ChunkScheduler.singleStream(fileSize),
    );

    await job.executeDownload(Dio());

    final tempFile = File(tempPath);
    expect(await tempFile.exists(), isTrue);
    expect(await tempFile.length(), equals(fileSize));
    expect(
      sha256.convert(await tempFile.readAsBytes()).toString(),
      equals(expectedSha256),
    );
    receivePort.close();
  });
}
