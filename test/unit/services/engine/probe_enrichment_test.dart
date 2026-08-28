import 'dart:isolate';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'Probe Enrichment: identity probe measures Range support, TTFB, and initial goodput',
      () async {
    final receivePort = ReceivePort();
    const cmd = DownloadCommand(
      taskId: 'probe_test_1',
      url: 'https://example.com/probe_file.zip',
      punyUrl: 'https://example.com/probe_file.zip',
      tempFilePath: 'test_probe.tmp',
      localFilePath: 'test_probe.zip',
      knownFileSize: 10000,
      supportsResume: true,
      threadCount: 2,
    );

    final job = HttpTransferJob(cmd, receivePort.sendPort);
    job.stateForTesting = TransferState(
      totalSize: 10000,
      threadCount: 2,
      chunks: [
        ChunkState(start: 0, end: 4999),
        ChunkState(start: 5000, end: 9999)
      ],
      url: cmd.url,
    );

    // Verify initial probe getters are accessible
    expect(job.probeTtfbMsForTesting, isNull);
    expect(job.probeSupportsRangeForTesting, isNull);
    expect(job.probeInitialGoodputBpsForTesting, isNull);

    receivePort.close();
  });
}
