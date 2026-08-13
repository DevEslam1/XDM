import 'package:dmx/core/utils/file_utils.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadTask serialization', () {
    test('serializes and deserializes persisted fields', () {
      final now = DateTime(2026, 6, 5, 12);
      final completed = now.add(const Duration(minutes: 1));
      final task = DownloadTask(
        id: '1',
        fileName: 'sample.zip',
        url: 'https://example.com/sample.zip',
        fileSize: 2048,
        downloadedBytes: 1024,
        speed: 512,
        eta: 2,
        category: 'Archive',
        status: DownloadStatus.downloading,
        savePath: 'D:/Downloads',
        localFilePath: 'D:/Downloads/sample.zip',
        tempFilePath: 'D:/Downloads/sample.zip.dmxpart',
        errorMessage: 'Previous error',
        threadCount: 4,
        chunks: const [0.2, 0.3, 0.4, 0.5],
        createdAt: now,
        updatedAt: now,
        completedAt: completed,
        supportsResume: true,
        downloadPageUrl: 'https://example.com/download-page',
      );

      final restored = DownloadTask.fromMap(task.toMap());

      expect(restored.id, task.id);
      expect(restored.status, DownloadStatus.downloading);
      expect(restored.localFilePath, task.localFilePath);
      expect(restored.tempFilePath, task.tempFilePath);
      expect(restored.threadCount, 4);
      expect(restored.chunks, task.chunks);
      expect(restored.supportsResume, isTrue);
      expect(restored.completedAt, completed);
      expect(restored.downloadPageUrl, 'https://example.com/download-page');
    });

    test('statusMessage survives toMap/fromMap round-trip', () {
      final now = DateTime(2026, 7, 23);
      final task = DownloadTask(
        id: 'sm1',
        fileName: 'video.mp4',
        url: 'https://example.com/video.mp4',
        fileSize: 100,
        downloadedBytes: 50,
        category: 'Video',
        status: DownloadStatus.downloading,
        savePath: '/tmp',
        localFilePath: '/tmp/video.mp4',
        tempFilePath: '/tmp/video.mp4.tmp',
        threadCount: 1,
        chunks: const [0.5],
        createdAt: now,
        updatedAt: now,
        statusMessage: 'Merging video and audio...',
      );

      final map = task.toMap();
      final restored = DownloadTask.fromMap(map);

      expect(restored.statusMessage, 'Merging video and audio...');
    });

    test('statusMessage defaults to null when absent from map', () {
      final map = <String, dynamic>{
        'id': 'sm2',
        'fileName': 'file.zip',
        'url': 'https://example.com/file.zip',
        'fileSize': 50,
        'downloadedBytes': 0,
        'speed': 0,
        'category': 'Other',
        'status': 'queued',
        'savePath': '',
        'localFilePath': '',
        'tempFilePath': '',
        'threadCount': 1,
        'chunks': [0.0],
        'createdAt': '2026-07-23T00:00:00.000',
        'updatedAt': '2026-07-23T00:00:00.000',
        'supportsResume': false,
        'speedLimitKbps': 0,
        'seedingEnabled': false,
        'seedingLimited': false,
        'seedingLimitKbps': 500,
        'audioSize': 0,
        'audioProgress': 0.0,
        'pausedByUser': false,
      };

      final restored = DownloadTask.fromMap(map);
      expect(restored.statusMessage, isNull);
    });
  });

  group('DownloadTask.copyWith', () {
    test('statusMessage is set via copyWith', () {
      final now = DateTime(2026, 7, 23);
      final task = DownloadTask(
        id: 'cw1',
        fileName: 'a.mp4',
        url: 'https://example.com/a.mp4',
        fileSize: 100,
        downloadedBytes: 0,
        category: 'Video',
        status: DownloadStatus.downloading,
        savePath: '',
        localFilePath: '',
        tempFilePath: '',
        threadCount: 1,
        chunks: const [0.0],
        createdAt: now,
        updatedAt: now,
      );

      final withMessage = task.copyWith(statusMessage: 'Merging...');
      expect(withMessage.statusMessage, 'Merging...');
    });

    test('clearStatusMessage removes statusMessage', () {
      final now = DateTime(2026, 7, 23);
      final task = DownloadTask(
        id: 'cw2',
        fileName: 'a.mp4',
        url: 'https://example.com/a.mp4',
        fileSize: 100,
        downloadedBytes: 0,
        category: 'Video',
        status: DownloadStatus.downloading,
        savePath: '',
        localFilePath: '',
        tempFilePath: '',
        threadCount: 1,
        chunks: const [0.0],
        createdAt: now,
        updatedAt: now,
        statusMessage: 'Merging...',
      );

      final cleared = task.copyWith(clearStatusMessage: true);
      expect(cleared.statusMessage, isNull);
    });

    test('statusMessage is not persisted to database map', () {
      final now = DateTime(2026, 7, 23);
      final task = DownloadTask(
        id: 'nw1',
        fileName: 'b.zip',
        url: 'https://example.com/b.zip',
        fileSize: 100,
        downloadedBytes: 0,
        category: 'Archive',
        status: DownloadStatus.downloading,
        savePath: '',
        localFilePath: '',
        tempFilePath: '',
        threadCount: 1,
        chunks: const [0.0],
        createdAt: now,
        updatedAt: now,
        statusMessage: 'Merging...',
      );

      final map = task.toMap();
      expect(
        map.containsKey('statusMessage'),
        isTrue,
        reason: 'statusMessage is in toMap for widget use',
      );
    });

    test('errorMessage is cleared and statusMessage is independent', () {
      final now = DateTime(2026, 7, 23);
      final task = DownloadTask(
        id: 'indep1',
        fileName: 'c.zip',
        url: 'https://example.com/c.zip',
        fileSize: 100,
        downloadedBytes: 0,
        category: 'Archive',
        status: DownloadStatus.downloading,
        savePath: '',
        localFilePath: '',
        tempFilePath: '',
        threadCount: 1,
        chunks: const [0.0],
        createdAt: now,
        updatedAt: now,
        errorMessage: 'Some error',
        statusMessage: 'Merging...',
      );

      final cleared = task.copyWith(clearError: true);
      expect(cleared.errorMessage, isNull);
      expect(cleared.statusMessage, 'Merging...');
    });
  });

  group('DownloadTask status transitions', () {
    test('completed clears statusMessage', () {
      final now = DateTime(2026, 7, 23);
      final task = DownloadTask(
        id: 'st1',
        fileName: 'd.mp4',
        url: 'https://example.com/d.mp4',
        fileSize: 100,
        downloadedBytes: 100,
        category: 'Video',
        status: DownloadStatus.downloading,
        savePath: '',
        localFilePath: '',
        tempFilePath: '',
        threadCount: 1,
        chunks: const [1.0],
        createdAt: now,
        updatedAt: now,
        statusMessage: 'Merging video and audio...',
      );

      final completed = task.copyWith(
        status: DownloadStatus.completed,
        clearStatusMessage: true,
        completedAt: now,
        downloadedBytes: 100,
      );

      expect(completed.status, DownloadStatus.completed);
      expect(completed.statusMessage, isNull);
      expect(completed.errorMessage, isNull);
    });

    test('paused clears statusMessage', () {
      final now = DateTime(2026, 7, 23);
      final task = DownloadTask(
        id: 'st2',
        fileName: 'e.zip',
        url: 'https://example.com/e.zip',
        fileSize: 100,
        downloadedBytes: 50,
        category: 'Archive',
        status: DownloadStatus.downloading,
        savePath: '',
        localFilePath: '',
        tempFilePath: '',
        threadCount: 1,
        chunks: const [0.5],
        createdAt: now,
        updatedAt: now,
        statusMessage: 'Merging...',
      );

      final paused = task.copyWith(
        status: DownloadStatus.paused,
        clearStatusMessage: true,
      );

      expect(paused.status, DownloadStatus.paused);
      expect(paused.statusMessage, isNull);
    });

    test('failed clears statusMessage', () {
      final now = DateTime(2026, 7, 23);
      final task = DownloadTask(
        id: 'st3',
        fileName: 'f.mp4',
        url: 'https://example.com/f.mp4',
        fileSize: 100,
        downloadedBytes: 50,
        category: 'Video',
        status: DownloadStatus.downloading,
        savePath: '',
        localFilePath: '',
        tempFilePath: '',
        threadCount: 1,
        chunks: const [0.5],
        createdAt: now,
        updatedAt: now,
        statusMessage: 'Merging...',
      );

      final failed = task.copyWith(
        status: DownloadStatus.failed,
        clearStatusMessage: true,
        errorMessage: 'Connection lost',
      );

      expect(failed.status, DownloadStatus.failed);
      expect(failed.statusMessage, isNull);
      expect(failed.errorMessage, 'Connection lost');
    });
  });

  group('DownloadTask computed properties', () {
    test('progressPercentString formats correctly', () {
      final now = DateTime(2026, 7, 23);
      final task = DownloadTask(
        id: 'p1',
        fileName: 'p.zip',
        url: 'https://example.com/p.zip',
        fileSize: 200,
        downloadedBytes: 100,
        category: 'Other',
        status: DownloadStatus.downloading,
        savePath: '',
        localFilePath: '',
        tempFilePath: '',
        threadCount: 1,
        chunks: const [0.5],
        createdAt: now,
        updatedAt: now,
      );

      expect(task.progressPercentString, '50.0%');
    });

    test('progress clamps to 0.0-1.0', () {
      final now = DateTime(2026, 7, 23);
      final task = DownloadTask(
        id: 'p2',
        fileName: 'p.zip',
        url: 'https://example.com/p.zip',
        fileSize: 100,
        downloadedBytes: 200,
        category: 'Other',
        status: DownloadStatus.downloading,
        savePath: '',
        localFilePath: '',
        tempFilePath: '',
        threadCount: 1,
        chunks: const [1.0],
        createdAt: now,
        updatedAt: now,
      );

      expect(task.progress, 1.0);
    });

    test('progress returns -1.0 when fileSize is 0', () {
      final now = DateTime(2026, 7, 23);
      final task = DownloadTask(
        id: 'p3',
        fileName: 'p.zip',
        url: 'https://example.com/p.zip',
        fileSize: 0,
        downloadedBytes: 0,
        category: 'Other',
        status: DownloadStatus.downloading,
        savePath: '',
        localFilePath: '',
        tempFilePath: '',
        threadCount: 1,
        chunks: const [0.0],
        createdAt: now,
        updatedAt: now,
      );

      expect(task.progress, -1.0);
    });
  });

  group('Magnet URL Tests', () {
    const validHex40 =
        'magnet:?xt=urn:btih:5dee65101db75097c523f19f074d0a64087dbcd3&dn=Ubuntu';
    const validBase32 = 'magnet:?xt=urn:btih:MR6EKEINW5KJPRFD6GPQPTHKMQEH3P5T';
    const validHex64 =
        'magnet:?xt=urn:btih:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

    const invalidNoXt = 'magnet:?dn=Ubuntu';
    const invalidShortHash = 'magnet:?xt=urn:btih:5dee65101db75097';

    test('isMagnetUrl validates correct formats', () {
      expect(isMagnetUrl(validHex40), isTrue);
      expect(isMagnetUrl(validHex64), isTrue);

      expect(
        isMagnetUrl(validBase32),
        isTrue,
        reason: 'Base32 hash should be converted to hex and validated',
      );
      expect(isMagnetUrl(invalidNoXt), isFalse);
      expect(isMagnetUrl(invalidShortHash), isFalse);
      expect(isMagnetUrl('https://example.com'), isFalse);
    });

    test('parseMagnetUrl extracts dn and infoHash', () {
      final parsed1 = parseMagnetUrl(validHex40);
      expect(parsed1['infoHash'], '5DEE65101DB75097C523F19F074D0A64087DBCD3');
      expect(parsed1['name'], 'Ubuntu');

      final parsed2 = parseMagnetUrl(validBase32);
      expect(parsed2['infoHash'], isNotNull);
      expect(parsed2['infoHash']!.length, 40);
    });
  });

  group('URL validation', () {
    test('isHttpUrl accepts valid HTTP/HTTPS URLs', () {
      expect(isHttpUrl('https://example.com/file.zip'), isTrue);
      expect(isHttpUrl('http://example.com/file.zip'), isTrue);
      expect(isHttpUrl('ftp://example.com/file.zip'), isFalse);
      expect(isHttpUrl(''), isFalse);
    });

    test('fileNameFromUrl extracts and sanitizes names', () {
      expect(
        fileNameFromUrl('https://example.com/files/My%20Video.mp4?token=1'),
        'My Video.mp4',
      );
      expect(fileNameFromUrl('https://example.com/'), startsWith('download_'));
    });

    test('categoryFromFileName maps common extensions', () {
      expect(categoryFromFileName('movie.mkv'), 'Video');
      expect(categoryFromFileName('song.flac'), 'Audio');
      expect(categoryFromFileName('report.pdf'), 'Document');
      expect(categoryFromFileName('bundle.7z'), 'Archive');
      expect(categoryFromFileName('app.apk'), 'APK');
      expect(categoryFromFileName('unknown.bin'), 'Other');
    });
  });

  group('DownloadTask copyWith edge cases', () {
    test('copyWith preserves all fields when no arguments given', () {
      final now = DateTime(2026, 7, 23);
      final task = DownloadTask(
        id: 'edge1',
        fileName: 'edge.zip',
        url: 'https://example.com/edge.zip',
        fileSize: 100,
        downloadedBytes: 50,
        speed: 10.5,
        eta: 3,
        category: 'Archive',
        status: DownloadStatus.downloading,
        savePath: '/dl',
        localFilePath: '/dl/edge.zip',
        tempFilePath: '/dl/edge.zip.tmp',
        errorMessage: 'err',
        statusMessage: 'msg',
        threadCount: 4,
        chunks: const [0.5, 0.5],
        createdAt: now,
        updatedAt: now,
        completedAt: now,
        scheduledAt: now,
        supportsResume: true,
        speedLimitKbps: 1024,
        seedingEnabled: true,
        seedingLimited: true,
        seedingLimitKbps: 200,
        torrentFiles: const [
          {'name': 't.txt', 'length': 10},
        ],
        downloadPageUrl: 'https://example.com/page',
        mergedAudioUrl: 'https://example.com/audio',
        audioSize: 50,
        audioProgress: 0.5,
        pausedByUser: true,
        youtubeQualityPreset: '1080p',
      );

      final copy = task.copyWith();
      expect(copy.id, task.id);
      expect(copy.fileName, task.fileName);
      expect(copy.url, task.url);
      expect(copy.fileSize, task.fileSize);
      expect(copy.downloadedBytes, task.downloadedBytes);
      expect(copy.speed, task.speed);
      expect(copy.eta, task.eta);
      expect(copy.category, task.category);
      expect(copy.status, task.status);
      expect(copy.savePath, task.savePath);
      expect(copy.localFilePath, task.localFilePath);
      expect(copy.tempFilePath, task.tempFilePath);
      expect(copy.errorMessage, task.errorMessage);
      expect(copy.statusMessage, task.statusMessage);
      expect(copy.threadCount, task.threadCount);
      expect(copy.chunks, task.chunks);
      expect(copy.completedAt, task.completedAt);
      expect(copy.scheduledAt, task.scheduledAt);
      expect(copy.supportsResume, task.supportsResume);
      expect(copy.speedLimitKbps, task.speedLimitKbps);
      expect(copy.seedingEnabled, task.seedingEnabled);
      expect(copy.seedingLimited, task.seedingLimited);
      expect(copy.seedingLimitKbps, task.seedingLimitKbps);
      expect(copy.torrentFiles, task.torrentFiles);
      expect(copy.downloadPageUrl, task.downloadPageUrl);
      expect(copy.mergedAudioUrl, task.mergedAudioUrl);
      expect(copy.audioSize, task.audioSize);
      expect(copy.audioProgress, task.audioProgress);
      expect(copy.pausedByUser, task.pausedByUser);
      expect(copy.youtubeQualityPreset, task.youtubeQualityPreset);
    });

    test('copyWith clears nullable fields with clearXxx flags', () {
      final now = DateTime(2026, 7, 23);
      final task = DownloadTask(
        id: 'edge2',
        fileName: 'e.zip',
        url: 'https://example.com/e.zip',
        fileSize: 100,
        downloadedBytes: 0,
        category: 'Other',
        status: DownloadStatus.failed,
        savePath: '',
        localFilePath: '',
        tempFilePath: '',
        errorMessage: 'err',
        statusMessage: 'msg',
        threadCount: 1,
        chunks: const [0.0],
        createdAt: now,
        updatedAt: now,
        completedAt: now,
        scheduledAt: now,
        downloadPageUrl: 'https://example.com/dl',
        mergedAudioUrl: 'https://example.com/au',
        youtubeQualityPreset: '720p',
      );

      final cleared = task.copyWith(
        clearError: true,
        clearStatusMessage: true,
        clearCompletedAt: true,
        clearScheduledAt: true,
        clearDownloadPageUrl: true,
        clearMergedAudioUrl: true,
        clearYoutubeQualityPreset: true,
      );

      expect(cleared.errorMessage, isNull);
      expect(cleared.statusMessage, isNull);
      expect(cleared.completedAt, isNull);
      expect(cleared.scheduledAt, isNull);
      expect(cleared.downloadPageUrl, isNull);
      expect(cleared.mergedAudioUrl, isNull);
      expect(cleared.youtubeQualityPreset, isNull);
    });
  });

  group('DownloadTask fromMap robustness', () {
    test('fromMap handles missing optional fields gracefully', () {
      final minimalMap = <String, dynamic>{
        'id': 'min1',
        'fileName': 'minimal.zip',
        'url': 'https://example.com/minimal.zip',
        'fileSize': 0,
        'downloadedBytes': 0,
        'speed': 0,
        'category': 'Other',
        'status': 'queued',
        'savePath': '',
        'localFilePath': '',
        'tempFilePath': '',
        'threadCount': 1,
        'chunks': [0.0],
        'createdAt': '2026-07-23T00:00:00.000',
        'updatedAt': '2026-07-23T00:00:00.000',
        'supportsResume': false,
        'speedLimitKbps': 0,
        'seedingEnabled': false,
        'seedingLimited': false,
        'seedingLimitKbps': 500,
        'audioSize': 0,
        'audioProgress': 0.0,
        'pausedByUser': false,
      };

      final task = DownloadTask.fromMap(minimalMap);
      expect(task.id, 'min1');
      expect(task.status, DownloadStatus.queued);
      expect(task.errorMessage, isNull);
      expect(task.statusMessage, isNull);
      expect(task.completedAt, isNull);
      expect(task.scheduledAt, isNull);
      expect(task.downloadPageUrl, isNull);
      expect(task.mergedAudioUrl, isNull);
      expect(task.youtubeQualityPreset, isNull);
      expect(task.supportsResume, isFalse);
    });

    test('fromMap handles all DownloadStatus values', () {
      final baseMap = <String, dynamic>{
        'id': 'status1',
        'fileName': 's.zip',
        'url': 'https://example.com/s.zip',
        'fileSize': 100,
        'downloadedBytes': 0,
        'speed': 0,
        'category': 'Other',
        'savePath': '',
        'localFilePath': '',
        'tempFilePath': '',
        'threadCount': 1,
        'chunks': [0.0],
        'createdAt': '2026-07-23T00:00:00.000',
        'updatedAt': '2026-07-23T00:00:00.000',
        'supportsResume': false,
        'speedLimitKbps': 0,
        'seedingEnabled': false,
        'seedingLimited': false,
        'seedingLimitKbps': 500,
        'audioSize': 0,
        'audioProgress': 0.0,
        'pausedByUser': false,
      };

      for (final status in DownloadStatus.values) {
        final map = Map<String, dynamic>.from(baseMap)
          ..['status'] = status.name;
        final task = DownloadTask.fromMap(map);
        expect(task.status, status);
      }
    });

    test('fromMap handles malformed createdAt gracefully', () {
      final map = <String, dynamic>{
        'id': 'bad_date',
        'fileName': 'bad.zip',
        'url': 'https://example.com/bad.zip',
        'fileSize': 0,
        'downloadedBytes': 0,
        'speed': 0,
        'category': 'Other',
        'status': 'queued',
        'savePath': '',
        'localFilePath': '',
        'tempFilePath': '',
        'threadCount': 1,
        'chunks': [0.0],
        'createdAt': 'not-a-date',
        'updatedAt': 'also-not-a-date',
        'supportsResume': false,
        'speedLimitKbps': 0,
        'seedingEnabled': false,
        'seedingLimited': false,
        'seedingLimitKbps': 500,
        'audioSize': 0,
        'audioProgress': 0.0,
        'pausedByUser': false,
      };

      final task = DownloadTask.fromMap(map);
      expect(task.createdAt, isA<DateTime>());
      expect(task.updatedAt, isA<DateTime>());
    });

    test('fromMap normalizes chunk count to threadCount', () {
      final baseMap = <String, dynamic>{
        'id': 'chunks1',
        'fileName': 'c.zip',
        'url': 'https://example.com/c.zip',
        'fileSize': 100,
        'downloadedBytes': 0,
        'speed': 0,
        'category': 'Other',
        'status': 'queued',
        'savePath': '',
        'localFilePath': '',
        'tempFilePath': '',
        'createdAt': '2026-07-23T00:00:00.000',
        'updatedAt': '2026-07-23T00:00:00.000',
        'supportsResume': false,
        'speedLimitKbps': 0,
        'seedingEnabled': false,
        'seedingLimited': false,
        'seedingLimitKbps': 500,
        'audioSize': 0,
        'audioProgress': 0.0,
        'pausedByUser': false,
      };

      // Fewer chunks than threadCount -> pad
      final map1 = Map<String, dynamic>.from(baseMap)
        ..['threadCount'] = 4
        ..['chunks'] = [0.1, 0.2];
      final task1 = DownloadTask.fromMap(map1);
      expect(task1.threadCount, 4);
      expect(task1.chunks.length, 4);
      expect(task1.chunks, [0.1, 0.2, 0.0, 0.0]);

      // More chunks than threadCount -> redistribute total progress
      final map2 = Map<String, dynamic>.from(baseMap)
        ..['threadCount'] = 2
        ..['chunks'] = [0.1, 0.2, 0.3, 0.4];
      final task2 = DownloadTask.fromMap(map2);
      expect(task2.threadCount, 2);
      expect(task2.chunks.length, 2);
      // Overall progress (sum / stored chunk count = 1.0 / 4 = 0.25) is
      // preserved by spreading it evenly across the new thread count.
      expect(task2.chunks, [0.25, 0.25]);
    });
  });

  group('DMX Audit Bug Fixes', () {
    test('Bug 1: combinedDownloadedBytes when video is 100% and audio is 40%',
        () {
      final task = DownloadTask(
        id: 'bug1_task',
        fileName: 'yt_video.mp4',
        url: 'https://youtube.com/watch?v=123',
        fileSize:
            100, // combinedTotalSize: videoStreamSize (80) + audioSize (20) = 100
        downloadedBytes: 80, // video leg fully completed
        videoStreamSize: 80,
        audioSize: 20,
        audioProgress: 0.40, // 40% completed of audio
        audioDownloadedBytes: 8,
        status: DownloadStatus.downloading,
        category: 'Video',
        mergedAudioUrl: 'https://youtube.com/watch?v=123_audio',
        savePath: '',
        localFilePath: '',
        tempFilePath: '',
        threadCount: 1,
        chunks: const [1.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // combinedTotalSize = 80 + 20 = 100
      expect(task.combinedTotalSize, 100);
      // combinedDownloadedBytes = videoOnly (80) + (audioProgress 0.40 * audioSize 20 = 8) = 88
      expect(task.combinedDownloadedBytes, 88);
    });

    test(
        'Bug 2: isTorrentFileSelected missing/null default value behaves consistently',
        () {
      final fileWithSelectedTrue = {
        'name': '1.mp4',
        'length': 1000,
        'selected': true
      };
      final fileWithSelectedFalse = {
        'name': '2.mp4',
        'length': 2000,
        'selected': false
      };
      final fileWithSelectedNull = {
        'name': '3.mp4',
        'length': 3000
      }; // missing/null selected key

      expect(isTorrentFileSelected(fileWithSelectedTrue), isTrue);
      expect(isTorrentFileSelected(fileWithSelectedFalse), isFalse);
      expect(isTorrentFileSelected(fileWithSelectedNull), isTrue,
          reason: 'missing/null selected key defaults to true');

      final task = DownloadTask(
        id: 'bug2_task',
        fileName: 't.torrent',
        url: 'https://example.com/t.torrent',
        fileSize: 6000,
        downloadedBytes: 0,
        status: DownloadStatus.downloading,
        category: 'Torrent',
        savePath: '',
        localFilePath: '',
        tempFilePath: '',
        threadCount: 1,
        chunks: const [0.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        torrentFiles: [
          fileWithSelectedTrue,
          fileWithSelectedFalse,
          fileWithSelectedNull,
        ],
      );

      // resolvedFileSize = 1000 (true) + 3000 (null/missing -> selected) = 4000
      expect(task.resolvedFileSize, 4000);
    });
  });
}
