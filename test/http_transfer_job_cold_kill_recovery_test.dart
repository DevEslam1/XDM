import 'dart:io'; // FIX-P0-1
import 'dart:isolate'; // FIX-P0-1
import 'package:dio/dio.dart'; // FIX-P0-1
import 'package:dmx/core/services/download_journal.dart'; // FIX-P0-1
import 'package:dmx/core/services/engine/engine_models.dart'; // FIX-P0-1
import 'package:dmx/core/services/engine/http_transfer_job.dart'; // FIX-P0-1
import 'package:flutter_test/flutter_test.dart'; // FIX-P0-1
import 'package:shared_preferences/shared_preferences.dart'; // FIX-P0-1

// FIX-P0-1
class _DummyAdapter implements HttpClientAdapter {
  // FIX-P0-1
  @override // FIX-P0-1
  Future<ResponseBody> fetch(
    // FIX-P0-1
    RequestOptions options, // FIX-P0-1
    Stream<List<int>>? requestStream, // FIX-P0-1
    Future<void>? cancelFuture, // FIX-P0-1
  ) async {
    // FIX-P0-1
    return ResponseBody(
      // FIX-P0-1
      const Stream.empty(), // FIX-P0-1
      200, // FIX-P0-1
      headers: {
        // FIX-P0-1
        'content-length': ['100000000'], // FIX-P0-1
      }, // FIX-P0-1
    ); // FIX-P0-1
  } // FIX-P0-1

  // FIX-P0-1
  @override // FIX-P0-1
  void close({bool force = false}) {} // FIX-P0-1
} // FIX-P0-1

// FIX-P0-1
void main() {
  // FIX-P0-1
  TestWidgetsFlutterBinding.ensureInitialized(); // FIX-P0-1
  // FIX-P0-1
  late Directory tempDir; // FIX-P0-1
  late String tempFilePath; // FIX-P0-1
  late String localFilePath; // FIX-P0-1
  // FIX-P0-1
  setUp(() async {
    // FIX-P0-1
    SharedPreferences.setMockInitialValues({}); // FIX-P0-1
    tempDir =
        await Directory.systemTemp.createTemp('cold_kill_test_'); // FIX-P0-1
    tempFilePath = '${tempDir.path}/download.tmp'; // FIX-P0-1
    localFilePath = '${tempDir.path}/download.bin'; // FIX-P0-1
  }); // FIX-P0-1
  // FIX-P0-1
  tearDown(() async {
    // FIX-P0-1
    if (await tempDir.exists()) {
      // FIX-P0-1
      await tempDir.delete(recursive: true); // FIX-P0-1
    } // FIX-P0-1
  }); // FIX-P0-1
  // FIX-P0-1
  test(
      'P0-1: simulates SIGKILL mid-chunk and verifies journal replay recovers within 1MB',
      () async {
    // FIX-P0-1
    const totalSize = 100 * 1024 * 1024; // 100 MB // FIX-P0-1
    const threadCount = 2; // FIX-P0-1
    const chunkSize = totalSize ~/ threadCount; // 50 MB // FIX-P0-1
    // FIX-P0-1
    // 1. Write an initial state file where chunk 0 has 20 MB and chunk 1 has 5 MB // FIX-P0-1
    final oldState = TransferState(
      // FIX-P0-1
      totalSize: totalSize, // FIX-P0-1
      threadCount: threadCount, // FIX-P0-1
      url: 'https://example.com/file.zip', // FIX-P0-1
      chunks: [
        // FIX-P0-1
        ChunkState(
            start: 0,
            end: chunkSize - 1,
            downloaded: 20 * 1024 * 1024), // FIX-P0-1
        ChunkState(
            start: chunkSize,
            end: totalSize - 1,
            downloaded: 5 * 1024 * 1024), // FIX-P0-1
      ], // FIX-P0-1
    ); // FIX-P0-1
    await StateStore.save(tempFilePath, oldState, durable: true); // FIX-P0-1
    // FIX-P0-1
    // Create the actual temp file with corresponding bytes // FIX-P0-1
    final f = File(tempFilePath); // FIX-P0-1
    final raf = await f.open(mode: FileMode.write); // FIX-P0-1
    await raf.truncate(totalSize); // FIX-P0-1
    await raf.close(); // FIX-P0-1
    // FIX-P0-1
    // 2. Simulate progressive chunk downloads logged in journal before sudden SIGKILL // FIX-P0-1
    final journal = DownloadJournal('$tempFilePath.journal'); // FIX-P0-1
    await journal.open(); // FIX-P0-1
    await journal.writeInit(threadCount, totalSize); // FIX-P0-1
    // Chunk 0 made progress up to 25 MB (5 MB ahead of saved state) // FIX-P0-1
    await journal.recordChunkProgress(0, 25 * 1024 * 1024); // FIX-P0-1
    // Chunk 1 made progress up to 10 MB (5 MB ahead of saved state) // FIX-P0-1
    await journal.recordChunkProgress(1, 10 * 1024 * 1024); // FIX-P0-1
    await journal
        .close(); // Simulates fsync flush to disk prior to kill // FIX-P0-1
    // FIX-P0-1
    // 3. Resume job after cold-kill // FIX-P0-1
    final receivePort = ReceivePort(); // FIX-P0-1
    final emittedEvents = <Map<String, dynamic>>[]; // FIX-P0-1
    // FIX-P0-1
    receivePort.listen((dynamic msg) {
      // FIX-P0-1
      if (msg is Map) {
        // FIX-P0-1
        emittedEvents.add(Map<String, dynamic>.from(msg)); // FIX-P0-1
      } // FIX-P0-1
    }); // FIX-P0-1
    // FIX-P0-1
    final cmd = DownloadCommand(
      // FIX-P0-1
      taskId: 'cold-kill-task', // FIX-P0-1
      url: 'https://example.com/file.zip', // FIX-P0-1
      punyUrl: 'https://example.com/file.zip', // FIX-P0-1
      tempFilePath: tempFilePath, // FIX-P0-1
      localFilePath: localFilePath, // FIX-P0-1
      threadCount: threadCount, // FIX-P0-1
      knownFileSize: totalSize, // FIX-P0-1
      supportsResume:
          false, // Prevents identity check from hitting network // FIX-P0-1
    ); // FIX-P0-1
    // FIX-P0-1
    final job = HttpTransferJob(cmd, receivePort.sendPort); // FIX-P0-1
    final dio = Dio(); // FIX-P0-1
    dio.httpClientAdapter = _DummyAdapter(); // FIX-P0-1
    // FIX-P0-1
    final state = await job.loadAndReconcileState(dio); // FIX-P0-1
    // FIX-P0-1
    // 4. Verify that state was reconciled from the journal // FIX-P0-1
    expect(state.chunks.length, equals(2)); // FIX-P0-1
    // Chunk 0 recovered to 25MB // FIX-P0-1
    expect(state.chunks[0].downloaded, equals(25 * 1024 * 1024)); // FIX-P0-1
    // Chunk 1 recovered to 10MB // FIX-P0-1
    expect(state.chunks[1].downloaded, equals(10 * 1024 * 1024)); // FIX-P0-1
    // FIX-P0-1
    // Total recovered bytes: 35 MB vs target 35 MB -> 0 delta (< 1 MB loss) // FIX-P0-1
    final recoveredTotal = state.downloadedBytes; // FIX-P0-1
    const expectedTarget = 35 * 1024 * 1024; // FIX-P0-1
    final dataLoss = (expectedTarget - recoveredTotal).abs(); // FIX-P0-1
    expect(dataLoss, lessThanOrEqualTo(1024 * 1024)); // FIX-P0-1
    // FIX-P0-1
    // 5. Verify verifying cycle state was emitted // FIX-P0-1
    await pumpEventQueue(); // FIX-P0-1
    final verifyingEvent = emittedEvents.any((e) {
      // FIX-P0-1
      final data = e['data'] as Map<String, dynamic>?; // FIX-P0-1
      return data != null &&
          data['cycleState'] == CycleState.verifying.name; // FIX-P0-1
    }); // FIX-P0-1
    expect(verifyingEvent, isTrue); // FIX-P0-1
    // FIX-P0-1
    receivePort.close(); // FIX-P0-1
  }); // FIX-P0-1
} // FIX-P0-1
