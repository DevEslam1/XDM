import 'dart:io';

import 'package:dmx/core/services/download_journal.dart';
import 'package:flutter_test/flutter_test.dart';

/// M3 (Plan 03 Task 3.5): the `.dmxstate` snapshot is written from two isolates
/// — the worker isolate writes byte-accurate progress, while the main isolate's
/// background/dataSync checkpoint reconstructs a coarser, staler snapshot from
/// DB-derived per-chunk fractions. The dedup caches are per-isolate, so the
/// stale-write guard in [StateStoreInstance.save] must consult the on-disk
/// snapshot directly and refuse any durable write that would regress byte
/// progress or un-complete a finished download.
void main() {
  late Directory dir;
  late String tempFilePath;
  const taskId = 'task-m3';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dmx_m3_');
    tempFilePath = '${dir.path}/file.bin';
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  TransferState state(int downloaded,
      {int total = 1000, DmxStateStatus status = DmxStateStatus.active}) {
    return TransferState(
      url: 'https://example.com/f',
      totalSize: total,
      threadCount: 1,
      chunks: [ChunkState(start: 0, end: total - 1, downloaded: downloaded)],
      status: status,
    );
  }

  test('coarse durable write does NOT regress a fresher on-disk snapshot',
      () async {
    // Worker isolate: fresh, byte-accurate snapshot at 500 bytes.
    final worker = StateStoreInstance();
    await worker.save(tempFilePath, state(500), durable: true, taskId: taskId);

    final path = worker.pathFor(tempFilePath, taskId: taskId);
    expect(await File(path).exists(), isTrue);

    // Main isolate: coarser/staler paused snapshot at 480 bytes reconstructed
    // from DB fractions. A distinct instance models the independent per-isolate
    // dedup cache, so only the on-disk guard can catch the regression.
    final main = StateStoreInstance();
    await main.save(tempFilePath, state(480, status: DmxStateStatus.paused),
        durable: true, taskId: taskId);

    final onDisk = await worker.load(tempFilePath, taskId: taskId);
    expect(onDisk, isNotNull);
    expect(onDisk!.downloadedBytes, 500,
        reason: 'stale 480-byte write must not clobber fresher 500-byte state');
    expect(onDisk.status, DmxStateStatus.active,
        reason: 'the fresher snapshot status is preserved');
  });

  test('a genuine forward durable write is still allowed to advance', () async {
    final store = StateStoreInstance();
    await store.save(tempFilePath, state(500), durable: true, taskId: taskId);
    await store.save(tempFilePath, state(600), durable: true, taskId: taskId);

    final onDisk = await store.load(tempFilePath, taskId: taskId);
    expect(onDisk, isNotNull);
    expect(onDisk!.downloadedBytes, 600,
        reason: 'forward progress must never be blocked by the guard');
  });

  test('a durable write must NOT un-complete a finished snapshot', () async {
    // Worker isolate finishes the download.
    final worker = StateStoreInstance();
    await worker.save(
        tempFilePath, state(1000, status: DmxStateStatus.complete),
        durable: true, taskId: taskId);

    // Main isolate later writes a paused snapshot (same byte count) — this must
    // not demote the completed snapshot back to paused.
    final main = StateStoreInstance();
    await main.save(tempFilePath, state(1000, status: DmxStateStatus.paused),
        durable: true, taskId: taskId);

    final onDisk = await worker.load(tempFilePath, taskId: taskId);
    expect(onDisk, isNotNull);
    expect(onDisk!.status, DmxStateStatus.complete,
        reason:
            'a completed snapshot must not be un-completed by a peer write');
  });
}
