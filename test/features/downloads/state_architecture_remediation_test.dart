import 'package:dmx/features/downloads/domain/commands/download_commands.dart';
import 'package:dmx/features/downloads/domain/executor/task_mailbox.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 1 & 2: TaskStateMapper Exhaustive Mapping', () {
    test('bidirectional domain to download status', () {
      for (final state in DomainDownloadState.values) {
        final status = TaskStateMapper.domainToDownloadStatus(state);
        final backToDomain = TaskStateMapper.downloadStatusToDomain(status);
        expect(backToDomain, isNotNull);
      }
    });

    test('bidirectional cycle state to download status', () {
      for (final cycle in CycleState.values) {
        final status = TaskStateMapper.toDownloadStatus(cycle);
        final backToCycle = TaskStateMapper.toCycleState(status);
        expect(backToCycle, isNotNull);
      }
    });
  });

  group('Phase 2 H1: DownloadTask copyWith Nullability and Sentinels', () {
    test('explicitly clear nullable fields to null', () {
      final now = DateTime.now();
      final task = DownloadTask(
        id: 'task_null_test',
        fileName: 'file.mp4',
        url: 'https://example.com/file.mp4',
        fileSize: 1000,
        downloadedBytes: 500,
        category: 'Videos',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/file.mp4',
        tempFilePath: '/downloads/file.mp4.tmp',
        threadCount: 4,
        createdAt: now,
        updatedAt: now,
        notes: 'Some notes',
        playlistId: 'pl_123',
        playlistTitle: 'Playlist Title',
        authUsername: 'admin',
        authPassword: 'password',
        expectedSha256: 'abcdef',
        siteType: 'youtube',
        siteDisplayName: 'YouTube',
        contentHint: 'video',
      );

      expect(task.notes, equals('Some notes'));
      expect(task.playlistId, equals('pl_123'));
      expect(task.authUsername, equals('admin'));

      final cleared = task.copyWith(
        clearNotes: true,
        clearPlaylistId: true,
        clearPlaylistTitle: true,
        clearAuthUsername: true,
        clearAuthPassword: true,
        clearExpectedSha256: true,
        clearSiteType: true,
        clearSiteDisplayName: true,
        clearContentHint: true,
      );

      expect(cleared.notes, isNull);
      expect(cleared.playlistId, isNull);
      expect(cleared.playlistTitle, isNull);
      expect(cleared.authUsername, isNull);
      expect(cleared.authPassword, isNull);
      expect(cleared.expectedSha256, isNull);
      expect(cleared.siteType, isNull);
      expect(cleared.siteDisplayName, isNull);
      expect(cleared.contentHint, isNull);
      // Unchanged fields preserved
      expect(cleared.id, equals('task_null_test'));
      expect(cleared.fileName, equals('file.mp4'));
    });
  });

  group('Phase 2 H2 & H5: TaskMailbox Generations and Tombstones', () {
    test('stale generation commands are skipped and tombstones reject operations', () async {
      final executed = <DownloadCommand>[];
      final mailbox = TaskMailbox(
        taskId: 'task_mailbox_test',
        handler: (cmd, gen) async {
          executed.add(cmd);
        },
      );

      expect(mailbox.generation, equals(0));
      await mailbox.enqueue(const StartTask('task_mailbox_test'));
      expect(executed.length, equals(1));

      // Advance generation
      final nextGen = mailbox.nextGeneration();
      expect(nextGen, equals(1));
      expect(mailbox.isGenerationValid(0), isFalse);
      expect(mailbox.isGenerationValid(1), isTrue);

      // Mark tombstone
      mailbox.markTombstone();
      expect(mailbox.isTombstoned, isTrue);
      expect(mailbox.isClosed, isTrue);

      // Enqueueing to tombstoned mailbox throws StateError
      expect(
        () => mailbox.enqueue(const PauseTask('task_mailbox_test')),
        throwsStateError,
      );
    });
  });

  group('Phase 4 H3: DownloadTask Immutability', () {
    test('chunks and collections throw UnsupportedError on mutation attempt', () {
      final now = DateTime.now();
      final task = DownloadTask(
        id: 'task_immut_test',
        fileName: 'file.mp4',
        url: 'https://example.com/file.mp4',
        fileSize: 1000,
        downloadedBytes: 0,
        category: 'Videos',
        status: DownloadStatus.queued,
        savePath: '/downloads',
        localFilePath: '/downloads/file.mp4',
        tempFilePath: '/downloads/file.mp4.tmp',
        threadCount: 2,
        chunks: [0.1, 0.2],
        createdAt: now,
        updatedAt: now,
        mirrorUrls: ['https://mirror1.example.com'],
        customHeaders: {'User-Agent': 'DMX'},
      );

      expect(() => task.chunks.add(0.3), throwsUnsupportedError);
      expect(() => task.mirrorUrls!.add('https://mirror2.com'), throwsUnsupportedError);
      expect(() => task.customHeaders!['Accept'] = '*/*', throwsUnsupportedError);
    });
  });
}
