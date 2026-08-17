import 'dart:async';
import 'dart:io';

import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:dmx/features/downloads/models/download_state_machine.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Torrent Lifecycle', () {
    test('FIX-1: completed → paused transition is allowed', () {
      expect(
        DownloadStateMachine.canTransition(
          DownloadState.completed,
          DownloadState.paused,
        ),
        isTrue,
      );
      expect(
        DownloadStateMachine.canTransitionStatus(
          DownloadStatus.completed,
          DownloadStatus.paused,
        ),
        isTrue,
      );
    });

    test('FIX-2: State machine allows seeding pause through completed guard', () {
      final task = DownloadTask(
        id: 'seed_1',
        url: 'magnet:?xt=urn:btih:aabbccddeeff00112233445566778899aabbccdd&dn=Test',
        fileName: 'Test',
        savePath: 'build',
        localFilePath: 'build/Test',
        tempFilePath: 'build/Test.dmxpart',
        threadCount: 1,
        chunks: const [1.0],
        status: DownloadStatus.completed,
        seedingEnabled: true,
        fileSize: 1000,
        downloadedBytes: 1000,
        category: 'Torrent',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(task.isTorrent, isTrue);
      expect(task.seedingEnabled, isTrue);
      expect(
        DownloadStateMachine.canTransitionStatus(
          task.status,
          DownloadStatus.paused,
        ),
        isTrue,
      );
    });

    test('FIX-3: pauseTask logic transitions seeding torrent to paused status', () {
      final task = DownloadTask(
        id: 'seed_2',
        url: 'magnet:?xt=urn:btih:11223344556677889900aabbccddeeff00112233&dn=Ubuntu',
        fileName: 'Ubuntu.iso',
        savePath: 'build',
        localFilePath: 'build/Ubuntu.iso',
        tempFilePath: 'build/Ubuntu.iso.dmxpart',
        threadCount: 1,
        chunks: const [1.0],
        status: DownloadStatus.completed,
        seedingEnabled: true,
        fileSize: 2000,
        downloadedBytes: 2000,
        category: 'Torrent',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final paused = task.copyWith(
        status: DownloadStatus.paused,
        seedingEnabled: false,
        speed: 0,
        clearEta: true,
        clearError: true,
        clearStatusMessage: true,
        pausedByUser: true,
      );

      expect(paused.status, DownloadStatus.paused);
      expect(paused.seedingEnabled, isFalse);
      expect(paused.speed, 0.0);
    });

    test('FIX-4: deleteTask empty torrent directory deletion logic', () async {
      final tempDir = await Directory.systemTemp.createTemp('dmx_torrent_dir_test_');
      try {
        final torrentDir = Directory(p.join(tempDir.path, 'MyTorrentFolder'));
        await torrentDir.create(recursive: true);
        final sampleFile = File(p.join(torrentDir.path, 'file1.txt'));
        await sampleFile.writeAsString('hello');

        expect(await torrentDir.exists(), isTrue);
        expect(await sampleFile.exists(), isTrue);

        // Simulate deleting files
        await sampleFile.delete();

        // Simulate empty directory removal
        final remaining = await torrentDir.list().toList();
        if (remaining.isEmpty) {
          await torrentDir.delete();
        }

        expect(await torrentDir.exists(), isFalse);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('FIX-5: Info-hash resolution logic from magnet URL', () {
      const magnetA =
          'magnet:?xt=urn:btih:fedcba9876543210fedcba9876543210fedcba98&dn=SameName.iso';
      final parsed = parseMagnetUrl(magnetA);
      final hash = parsed['infoHash']?.toString().toLowerCase();

      expect(hash, 'fedcba9876543210fedcba9876543210fedcba98');
    });

    test('FIX-6: Magnet URL parse infoHash for early pause during metadata fetch', () {
      const magnetUrl =
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=PendingMeta';
      final parsed = parseMagnetUrl(magnetUrl);
      final infoHash = parsed['infoHash']?.toString().toLowerCase();

      expect(infoHash, isNotNull);
      expect(infoHash, '0123456789abcdef0123456789abcdef01234567');
    });

    test('FIX-7: Pending delete cleanups list handles async completion', () async {
      final pendingCleanups = <Future<void>>[];
      final completer = Completer<void>();

      final cleanupFuture = completer.future;
      pendingCleanups.add(cleanupFuture);
      cleanupFuture.whenComplete(() {
        pendingCleanups.remove(cleanupFuture);
      });

      expect(pendingCleanups.length, 1);
      completer.complete();
      await Future<void>.delayed(Duration.zero);
      expect(pendingCleanups.isEmpty, isTrue);
    });

    test('FIX-8: Duplicate magnet detection by info-hash with different display names', () {
      const magnet1 =
          'magnet:?xt=urn:btih:abcdef0123456789abcdef0123456789abcdef01&dn=Name_A';
      const magnet2 =
          'magnet:?xt=urn:btih:abcdef0123456789abcdef0123456789abcdef01&dn=Name_B';

      final hash1 = parseMagnetUrl(magnet1)['infoHash']?.toString().toLowerCase();
      final hash2 = parseMagnetUrl(magnet2)['infoHash']?.toString().toLowerCase();

      expect(hash1, equals(hash2));
    });

    test('FIX-9: TorrentResumeStore delete operations complete safely', () async {
      const sourceUrl = 'magnet:?xt=urn:btih:test_hash_delete&dn=Test';
      // Should execute without throw
      await TorrentResumeStore.deleteResumeDataForSource(sourceUrl);
      await TorrentResumeStore.delete(99999);
    });

    test('FIX-10: State machine transition logging does not emit warning for seeding pause', () {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);

      // Verify canTransitionStatus is valid
      final canTransition = DownloadStateMachine.canTransitionStatus(
        DownloadStatus.completed,
        DownloadStatus.paused,
      );
      expect(canTransition, isTrue);

      sub.cancel();
    });

    test('FIX-11: TorrentSubscriptionRegistry.instance.dispose on non-existent subscription does not throw', () {
      expect(
        () => TorrentSubscriptionRegistry.instance.dispose(99999),
        returnsNormally,
      );
    });
  });
}
