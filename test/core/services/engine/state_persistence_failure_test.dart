import 'dart:io';

import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_exceptions.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:flutter_test/flutter_test.dart';

/// F26 regression: when resume state cannot be persisted (EACCES / EROFS —
/// typical of an Android public directory the app cannot write), StateStore
/// must record the failure so the download aborts with an actionable storage
/// error instead of silently sitting at 0% and later failing with a generic
/// "File system error".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('f26_state_persist_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  TransferState stateFor(int total) => TransferState(
        totalSize: total,
        threadCount: 1,
        chunks: [
          ChunkState(start: 0, end: total - 1, downloaded: 0),
        ],
      );

  test('PathAccessException (errno 13) is a permanent write failure', () {
    const e = PathAccessException(
      "Cannot open file, path = '/x/y.dmxstate' "
          '(OS Error: Permission denied, errno = 13)',
      OSError('Permission denied', 13),
      '/x/y.dmxstate',
    );
    expect(e, isA<FileSystemException>());
    expect(StateStore.isPermanentWriteFailure(e), isTrue);
    expect(StateStore.isPermanentWriteFailure('nope'), isFalse);
    expect(
      StateStore.isPermanentWriteFailure(
        const FileSystemException('Connection reset by peer'),
      ),
      isFalse,
    );
  });

  test('a failed state write is recorded (permanent only for EACCES/EROFS)',
      () async {
    // Point the state file at a path whose parent is a *file*, so creating the
    // state (and its .tmp sibling) deterministically fails with a filesystem
    // error — a portable stand-in for a folder that rejects writes.
    final blocker = File('${tempDir.path}/blocker');
    await blocker.writeAsString('x');
    final tempPath = '${blocker.path}/download.bin.dmxpart';

    await StateStore.save(
      tempPath,
      stateFor(1000),
      durable: true,
      taskId: 'f26',
    );

    // The failure must be observable on the store (rather than only counted),
    // so the engine can react. A not-found/IO error is transient-class, so the
    // permanent flag is false; a real EACCES on Android reports true (covered
    // by the PathAccessException test above).
    expect(StateStore.instance.lastSaveErrorsForTesting.keys,
        contains(StateStore.pathFor(tempPath, taskId: 'f26')),
        reason: 'a failed state write must be recorded for the engine to see');

    // A subsequent successful save clears the recorded failure.
    final goodPath = '${tempDir.path}/good.bin.dmxpart';
    await StateStore.save(goodPath, stateFor(1000),
        durable: true, taskId: 'f26');
    expect(
      StateStore.hasPermanentSaveFailure(goodPath, taskId: 'f26'),
      isFalse,
    );
    expect(
      StateStore.instance.lastSaveErrorsForTesting
          .containsKey(StateStore.pathFor(goodPath, taskId: 'f26')),
      isFalse,
    );
  });

  test('StatePersistenceException classifies as an actionable storage error',
      () {
    const e = StatePersistenceException(
      'Cannot write resume data to the download folder. '
      'Pick a different folder or grant storage access.',
      directory: '/storage/emulated/0/Download/XDM',
    );
    final c = ErrorTaxonomy.classify(e);
    expect(c.family.name, 'disk');
    expect(c.retryable, isFalse);
    expect(c.message, contains('download folder'));
    expect(c.message, contains('/storage/emulated/0/Download/XDM'));
  });
}
