import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadTask _task({
  String id = 't1',
  String fileName = 'file.zip',
  String url = 'https://example.com/file.zip',
  int fileSize = 1000,
  int downloadedBytes = 0,
  double speed = 0.0,
  int? eta,
  String category = 'Other',
  DownloadStatus status = DownloadStatus.downloading,
  String savePath = '/s',
  String localFilePath = '/s/file.zip',
  String tempFilePath = '/s/file.zip.dmxpart',
  String? errorMessage,
  String? statusMessage,
  FailureCategory? failureCategory,
  String? recoveryHint,
  int threadCount = 2,
  List<double> chunks = const [0.0, 0.0],
  DateTime? createdAt,
  DateTime? updatedAt,
  DateTime? completedAt,
  DateTime? scheduledAt,
  DateTime? wasScheduledAt,
  bool supportsResume = false,
  int speedLimitKbps = 0,
  bool seedingEnabled = false,
  bool seedingLimited = false,
  int seedingLimitKbps = 500,
  int uploadedBytes = 0,
  List<Map<String, dynamic>>? torrentFiles,
  String? downloadPageUrl,
  String? mergedAudioUrl,
  int audioSize = 0,
  int audioDownloadedBytes = 0,
  int videoStreamSize = 0,
  double audioProgress = 0.0,
  int audioThreadCount = 2,
  bool isMergeInProgress = false,
  bool resumeDataSaved = false,
  bool pausedByUser = false,
  bool isCancelled = false,
  String? youtubeQualityPreset,
  String? notes,
  String? authUsername,
  String? authPassword,
  Map<String, String>? customHeaders,
  bool isAppUpdate = false,
  int priority = 0,
  int queueOrder = 0,
  String? playlistId,
  String? playlistTitle,
  String? thumbnailUrl,
  String? expectedSha256,
  List<String>? mirrorUrls,
  String? siteType,
  String? siteDisplayName,
  String? contentHint,
  PauseReason? pauseReason,
  int? totalPieces,
  int? completedPieces,
  int? ytCounterpartDownloadedBytes,
  CycleState? cycleState,
  CycleState? previousCycleState,
  int? totalFiles,
  int? completedFiles,
  int? totalFileBytes,
  int? downloadedFileBytes,
  int? torrentId,
  String? infoHash,
}) {
  final now = DateTime(2026, 1, 1, 12);
  return DownloadTask(
    id: id,
    fileName: fileName,
    url: url,
    fileSize: fileSize,
    downloadedBytes: downloadedBytes,
    speed: speed,
    eta: eta,
    category: category,
    status: status,
    savePath: savePath,
    localFilePath: localFilePath,
    tempFilePath: tempFilePath,
    errorMessage: errorMessage,
    statusMessage: statusMessage,
    failureCategory: failureCategory,
    recoveryHint: recoveryHint,
    threadCount: threadCount,
    chunks: chunks,
    createdAt: createdAt ?? now,
    updatedAt: updatedAt ?? now,
    completedAt: completedAt,
    scheduledAt: scheduledAt,
    wasScheduledAt: wasScheduledAt,
    supportsResume: supportsResume,
    speedLimitKbps: speedLimitKbps,
    seedingEnabled: seedingEnabled,
    seedingLimited: seedingLimited,
    seedingLimitKbps: seedingLimitKbps,
    uploadedBytes: uploadedBytes,
    torrentFiles: torrentFiles,
    downloadPageUrl: downloadPageUrl,
    mergedAudioUrl: mergedAudioUrl,
    audioSize: audioSize,
    audioDownloadedBytes: audioDownloadedBytes,
    videoStreamSize: videoStreamSize,
    audioProgress: audioProgress,
    audioThreadCount: audioThreadCount,
    isMergeInProgress: isMergeInProgress,
    resumeDataSaved: resumeDataSaved,
    pausedByUser: pausedByUser,
    isCancelled: isCancelled,
    youtubeQualityPreset: youtubeQualityPreset,
    notes: notes,
    authUsername: authUsername,
    authPassword: authPassword,
    customHeaders: customHeaders,
    isAppUpdate: isAppUpdate,
    priority: priority,
    queueOrder: queueOrder,
    playlistId: playlistId,
    playlistTitle: playlistTitle,
    thumbnailUrl: thumbnailUrl,
    expectedSha256: expectedSha256,
    mirrorUrls: mirrorUrls,
    siteType: siteType,
    siteDisplayName: siteDisplayName,
    contentHint: contentHint,
    pauseReason: pauseReason,
    totalPieces: totalPieces,
    completedPieces: completedPieces,
    ytCounterpartDownloadedBytes: ytCounterpartDownloadedBytes,
    cycleState: cycleState,
    previousCycleState: previousCycleState,
    totalFiles: totalFiles,
    completedFiles: completedFiles,
    totalFileBytes: totalFileBytes,
    downloadedFileBytes: downloadedFileBytes,
    torrentId: torrentId,
    infoHash: infoHash,
  );
}

DownloadTask _fullTask() => _task(
      id: 'full',
      fileName: 'full.mkv',
      url: 'magnet:?xt=urn:btih:abcdef',
      fileSize: 4096,
      downloadedBytes: 2048,
      speed: 512.5,
      eta: 30,
      category: 'Video',
      status: DownloadStatus.downloading,
      errorMessage: 'oops',
      statusMessage: 'busy',
      failureCategory: FailureCategory.network,
      recoveryHint: 'retry',
      threadCount: 4,
      chunks: const [0.1, 0.2, 0.3, 0.4],
      supportsResume: true,
      speedLimitKbps: 100,
      seedingEnabled: true,
      seedingLimited: true,
      seedingLimitKbps: 250,
      uploadedBytes: 128,
      torrentFiles: [
        {
          'name': 'a.bin',
          'length': 100,
          'downloadedBytes': 50,
          'selected': true
        },
      ],
      downloadPageUrl: 'https://example.com/page',
      mergedAudioUrl: 'https://example.com/audio',
      audioSize: 512,
      audioDownloadedBytes: 256,
      videoStreamSize: 3584,
      audioProgress: 0.5,
      audioThreadCount: 3,
      isMergeInProgress: true,
      resumeDataSaved: true,
      pausedByUser: true,
      isCancelled: true,
      youtubeQualityPreset: 'audio_only',
      notes: 'note',
      authUsername: 'user',
      authPassword: 'pass',
      customHeaders: {'X-Test': '1'},
      isAppUpdate: true,
      priority: 2,
      queueOrder: 7,
      playlistId: 'pl1',
      playlistTitle: 'Playlist',
      thumbnailUrl: 'https://example.com/thumb.jpg',
      expectedSha256: 'deadbeef',
      mirrorUrls: ['https://mirror.example.com/f'],
      siteType: 'youtube',
      siteDisplayName: 'YouTube',
      contentHint: 'video',
      pauseReason: PauseReason.networkLost,
      totalPieces: 10,
      completedPieces: 5,
      ytCounterpartDownloadedBytes: 111,
      cycleState: CycleState.downloading,
      previousCycleState: CycleState.starting,
      totalFiles: 3,
      completedFiles: 1,
      totalFileBytes: 900,
      downloadedFileBytes: 300,
      torrentId: 42,
      infoHash: 'hash',
    );

void main() {
  group('DownloadTaskBuilder', () {
    test('fromTask copies every field and build round-trips it', () {
      final task = _fullTask();
      final builder = task.toBuilder();

      expect(builder.id, task.id);
      expect(builder.fileName, task.fileName);
      expect(builder.torrentFiles, task.torrentFiles);
      expect(builder.customHeaders, task.customHeaders);
      expect(builder.mirrorUrls, task.mirrorUrls);
      expect(builder.resumeDataSaved, task.resumeDataSaved);

      final rebuilt = builder.build();
      expect(rebuilt.id, task.id);
      expect(rebuilt.fileName, task.fileName);
      expect(rebuilt.mergedAudioUrl, task.mergedAudioUrl);
      expect(rebuilt.audioSize, task.audioSize);
      expect(rebuilt.customHeaders, task.customHeaders);
      expect(rebuilt.mirrorUrls, task.mirrorUrls);
      expect(rebuilt.cycleState, task.cycleState);
      expect(rebuilt.previousCycleState, task.previousCycleState);
      expect(rebuilt.torrentId, task.torrentId);
      expect(rebuilt.resumeDataSaved, task.resumeDataSaved);
    });

    test('mutating the builder then build returns the mutated task', () {
      final builder = _fullTask().toBuilder()
        ..status = DownloadStatus.completed
        ..downloadedBytes = 4096
        ..chunks = [1.0, 1.0]
        ..torrentFiles = [
          {'name': 'z.bin', 'length': 1, 'selected': true},
        ]
        ..mirrorUrls = ['https://m2']
        ..customHeaders = {'A': 'B'}
        ..resumeDataSaved = false;

      final built = builder.build();
      expect(built.status, DownloadStatus.completed);
      expect(built.downloadedBytes, 4096);
      expect(built.chunks, [1.0, 1.0]);
      expect(built.torrentFiles, hasLength(1));
      expect(built.mirrorUrls, ['https://m2']);
      expect(built.customHeaders, {'A': 'B'});
      expect(built.resumeDataSaved, isFalse);
    });

    test('fromTask does not alias the source lists/maps', () {
      final task = _fullTask();
      final builder = task.toBuilder();
      builder.chunks = [0.9, 0.9];
      builder.customHeaders = {'changed': 'yes'};
      expect(task.chunks, isNot([0.9, 0.9]));
      expect(task.customHeaders, isNot({'changed': 'yes'}));
    });
  });

  group('equality and hashCode', () {
    test('identical and value-equal tasks compare equal', () {
      final a = _task(id: 'eq');
      final b = _task(id: 'eq');
      expect(a, equals(a));
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('speed comparison tolerates sub-0.5 drift', () {
      final a = _task(id: 's', speed: 100.0);
      expect(a, equals(_task(id: 's', speed: 100.4)));
      expect(a, isNot(equals(_task(id: 's', speed: 100.5))));
    });

    test('torrentFiles are compared per-entry, not by identity', () {
      final files = [
        {'name': 'a', 'length': 1, 'downloadedBytes': 0},
      ];
      final a = _task(id: 'tf', torrentFiles: files);
      final b = _task(id: 'tf', torrentFiles: [
        {'name': 'a', 'length': 1, 'downloadedBytes': 0},
      ]);
      expect(a, equals(b));
      final c = _task(id: 'tf', torrentFiles: [
        {'name': 'a', 'length': 2, 'downloadedBytes': 0},
      ]);
      expect(a, isNot(equals(c)));
    });

    test('null torrentFiles only equals null torrentFiles', () {
      final a = _task(id: 'n');
      final b = _task(id: 'n', torrentFiles: [
        {'name': 'a', 'length': 1},
      ]);
      expect(a, isNot(equals(b)));
    });

    test('differences in scalar fields break equality', () {
      final a = _task(id: 'd');
      expect(a, isNot(equals(_task(id: 'd', status: DownloadStatus.paused))));
      expect(a, isNot(equals(_task(id: 'd', errorMessage: 'x'))));
      expect(a, isNot(equals(_task(id: 'd', category: 'Video'))));
      expect(a, isNot(equals(_task(id: 'd', threadCount: 8))));
      expect(a, isNot(equals(_task(id: 'd', uploadedBytes: 1))));
      expect(a, isNot(equals(_task(id: 'd', torrentId: 5))));
    });
  });

  group('toMap / fromMap', () {
    test('round-trips every populated field', () {
      final task = _fullTask();
      final restored = DownloadTask.fromMap(task.toMap());
      expect(restored.id, task.id);
      expect(restored.failureCategory, FailureCategory.network);
      expect(restored.recoveryHint, 'retry');
      expect(restored.customHeaders, task.customHeaders);
      expect(restored.mirrorUrls, task.mirrorUrls);
      expect(restored.pauseReason, PauseReason.networkLost);
      expect(restored.cycleState, CycleState.downloading);
      // previousCycleState is intentionally not persisted by toMap.
      expect(restored.previousCycleState, isNull);
      expect(restored.torrentId, 42);
      expect(restored.infoHash, 'hash');
      expect(restored.completedAt, isNull);
    });

    test('parses dates from int, double, numeric string and ISO string', () {
      final map = _task(id: 'dates').toMap()
        ..['createdAt'] = 1700000000000
        ..['updatedAt'] = 1700000000000.0
        ..['completedAt'] = '1700000000000'
        ..['scheduledAt'] = '2026-01-02T03:04:05.000'
        ..['wasScheduledAt'] = 'not-a-date';
      final restored = DownloadTask.fromMap(map);
      expect(restored.createdAt.millisecondsSinceEpoch, 1700000000000);
      expect(restored.updatedAt.millisecondsSinceEpoch, 1700000000000);
      expect(restored.completedAt, isNotNull);
      expect(restored.scheduledAt, isNotNull);
      expect(restored.wasScheduledAt, isNull);
    });

    test('unknown status becomes paused with a recovery error', () {
      final restored = DownloadTask.fromMap({
        'status': 'definitely-not-real',
        'chunks': [0.0],
        'threadCount': 1,
      });
      expect(restored.status, DownloadStatus.paused);
      expect(restored.errorMessage, contains('Unknown status'));
    });

    test('unknown failureCategory falls back to unknown', () {
      final map = _task().toMap()..['failureCategory'] = 'bogus';
      expect(
          DownloadTask.fromMap(map).failureCategory, FailureCategory.unknown);
    });

    test('pauseReason accepts string, enum and other types', () {
      expect(
        DownloadTask.fromMap(_task().toMap()..['pauseReason'] = 'timeout')
            .pauseReason,
        PauseReason.timeout,
      );
      expect(
        DownloadTask.fromMap(
                _task().toMap()..['pauseReason'] = PauseReason.diskFull)
            .pauseReason,
        PauseReason.diskFull,
      );
      expect(
        DownloadTask.fromMap(_task().toMap()..['pauseReason'] = 99).pauseReason,
        isNull,
      );
    });

    test('cycleState accepts string and enum forms', () {
      expect(
        DownloadTask.fromMap(_task().toMap()..['cycleState'] = 'seeding')
            .cycleState,
        CycleState.seeding,
      );
      expect(
        DownloadTask.fromMap(
                _task().toMap()..['cycleState'] = CycleState.merging)
            .cycleState,
        CycleState.merging,
      );
    });

    test('pads chunks when fewer than threadCount', () {
      final restored = DownloadTask.fromMap({
        'status': 'downloading',
        'chunks': [0.5],
        'threadCount': 3,
      });
      expect(restored.chunks, [0.5, 0.0, 0.0]);
    });

    test('redistributes chunks when more than threadCount', () {
      final restored = DownloadTask.fromMap({
        'status': 'downloading',
        'chunks': [0.2, 0.4, 0.6, 0.8],
        'threadCount': 2,
      });
      expect(restored.chunks, hasLength(2));
      expect(restored.chunks[0], closeTo(0.5, 1e-9));
      expect(restored.chunks[1], closeTo(0.5, 1e-9));
    });

    test('uses byte ratio when chunk list is empty and threadCount negative',
        () {
      final restored = DownloadTask.fromMap({
        'status': 'downloading',
        'chunks': <double>[],
        'threadCount': -1,
        'downloadedBytes': 25,
        'fileSize': 100,
      });
      expect(restored.chunks, hasLength(1));
      expect(restored.chunks.first, closeTo(0.25, 1e-9));
    });

    test('derives torrent file aggregates from the file list', () {
      final restored = DownloadTask.fromMap({
        'status': 'downloading',
        'chunks': [0.0],
        'threadCount': 1,
        'torrentFiles': [
          {
            'name': 'a',
            'length': 100,
            'downloadedBytes': 50,
            'selected': true,
          },
          {
            'name': 'b',
            'length': 0,
            'downloadedBytes': 0,
            'selected': true,
            'isComplete': true,
            'lengthKnown': true,
          },
          {
            'name': 'c',
            'length': 0,
            'downloadedBytes': 0,
            'selected': true,
            'isComplete': true,
          },
          {
            'name': 'd',
            'length': 10,
            'downloadedBytes': 10,
            'selected': false,
          },
        ],
      });
      expect(restored.totalFiles, 3);
      expect(restored.completedFiles, 1);
      expect(restored.totalFileBytes, 100);
      expect(restored.downloadedFileBytes, 50);
    });

    test('missing fields fall back to defaults', () {
      final restored = DownloadTask.fromMap(const <String, dynamic>{});
      expect(restored.id, '');
      expect(restored.fileName, '');
      expect(restored.category, 'Other');
      expect(restored.status, DownloadStatus.paused);
      expect(restored.seedingLimitKbps, 500);
      expect(restored.videoStreamSize, 0);
      expect(restored.chunks, [0.0]);
    });

    test('negative videoStreamSize is clamped to zero', () {
      final restored =
          DownloadTask.fromMap(_task().toMap()..['videoStreamSize'] = -5);
      expect(restored.videoStreamSize, 0);
    });
  });

  group('getters', () {
    test('resolvedFileSize handles missing / torrent / aggregate sizes', () {
      expect(_task(fileSize: -1).resolvedFileSize, 0);
      expect(_task(fileSize: 500).resolvedFileSize, 500);
      final torrent = _task(
        url: 'magnet:?xt=urn:btih:a',
        fileSize: 0,
        torrentFiles: [
          {'name': 'a', 'length': 100, 'selected': true},
          {'name': 'b', 'length': 50, 'selected': true},
        ],
      );
      expect(torrent.resolvedFileSize, 150);
      final aggregate = _task(
        url: 'magnet:?xt=urn:btih:a',
        fileSize: 0,
        totalFileBytes: 777,
      );
      expect(aggregate.resolvedFileSize, 777);
    });

    test('audio getters prefer byte counts', () {
      final t = _task(audioSize: 100, audioDownloadedBytes: 25);
      expect(t.audioProgressPercent, closeTo(0.25, 1e-9));
      expect(t.audioProgressString, '25.0%');
      expect(t.isAudioComplete, isFalse);
      expect(
        _task(audioSize: 100, audioDownloadedBytes: 100).isAudioComplete,
        isTrue,
      );
      expect(
          _task(audioProgress: 0.4).audioProgressPercent, closeTo(0.4, 1e-9));
    });

    test('seedingRatio guards divide by zero', () {
      expect(_task(downloadedBytes: 0).seedingRatio, 0.0);
      expect(_task(downloadedBytes: 100, uploadedBytes: 250).seedingRatio, 2.5);
    });

    test('isTotalSizePartial requires merged audio with unknown video size',
        () {
      expect(
        _task(mergedAudioUrl: 'a', fileSize: 0, audioSize: 10)
            .isTotalSizePartial,
        isTrue,
      );
      expect(
        _task(mergedAudioUrl: 'a', fileSize: 10, audioSize: 10)
            .isTotalSizePartial,
        isFalse,
      );
    });

    test('waiting status getters match messages', () {
      expect(
          _task(errorMessage: DownloadStatusMessages.waitingWifi).waitingWifi,
          isTrue);
      expect(
        _task(statusMessage: DownloadStatusMessages.waitingNetwork)
            .waitingNetwork,
        isTrue,
      );
      expect(
        _task(errorMessage: DownloadStatusMessages.waitingCharging)
            .waitingCharging,
        isTrue,
      );
      expect(_task().hasTorrentFiles, isFalse);
      expect(
        _task(torrentFiles: [
          {'name': 'a', 'length': 1},
        ]).hasTorrentFiles,
        isTrue,
      );
    });

    test('torrentFileAggregates skips unselected and flags placeholders', () {
      final t = _task(
        url: 'magnet:?xt=urn:btih:a',
        torrentFiles: [
          {
            'name': 'a',
            'length': 100,
            'downloadedBytes': 40,
            'selected': true,
          },
          {
            'name': 'b',
            'length': 200,
            'downloadedBytes': 200,
            'selected': true,
            'isComplete': true,
          },
          {'name': 'c', 'length': 300, 'selected': false},
        ],
      );
      final agg = t.torrentFileAggregates;
      expect(agg.totalFileBytes, 300);
      expect(agg.downloadedFileBytes, 240);
      expect(agg.anyMeasured, isTrue);

      final estimated = _task(
        url: 'magnet:?xt=urn:btih:a',
        torrentFiles: [
          {
            'name': 'a',
            'length': 100,
            'downloadedBytes': 50,
            'selected': true,
            'progressEstimated': true,
          },
        ],
      );
      expect(estimated.torrentFileAggregates.anyMeasured, isFalse);
      expect(_task().torrentFileAggregates.totalFileBytes, 0);
    });

    test('torrentOverallPercent handles completed, ratio and fallback paths',
        () {
      expect(
          _task(status: DownloadStatus.completed).torrentOverallPercent, 1.0);

      final ratio = _task(
        url: 'magnet:?xt=urn:btih:a',
        fileSize: 100,
        downloadedBytes: 50,
      );
      expect(ratio.torrentOverallPercent, closeTo(0.5, 1e-9));

      final measuredFallback = _task(
        url: 'magnet:?xt=urn:btih:a',
        fileSize: 0,
        downloadedBytes: 0,
        torrentFiles: [
          {
            'name': 'a',
            'length': 100,
            'downloadedBytes': 50,
            'selected': true,
          },
        ],
      );
      expect(measuredFallback.torrentOverallPercent, closeTo(0.5, 1e-9));

      final knownTotalNoProgress = _task(
        url: 'magnet:?xt=urn:btih:a',
        fileSize: 100,
        downloadedBytes: 0,
      );
      expect(knownTotalNoProgress.torrentOverallPercent, 0.0);

      final plainFallback = _task(
        fileSize: 100,
        downloadedBytes: 25,
      );
      expect(plainFallback.torrentOverallPercent, closeTo(0.25, 1e-9));
    });

    test('combined size/bytes include merged audio', () {
      final t = _task(
        mergedAudioUrl: 'a',
        fileSize: 100,
        downloadedBytes: 40,
        audioSize: 50,
        audioDownloadedBytes: 10,
      );
      expect(t.combinedTotalSize, 150);
      expect(t.combinedDownloadedBytes, 50);
      expect(t.displayDownloadedBytes, 50);
    });

    test('combinedTotalSize falls back to downloaded page size', () {
      final t = _task(
        mergedAudioUrl: 'a',
        fileSize: 0,
        downloadedBytes: 30,
        audioSize: 0,
        audioDownloadedBytes: 0,
      );
      expect(t.combinedTotalSize, 30);
    });

    test('combinedTotalSize is zero when video size is unknown', () {
      final t = _task(
        mergedAudioUrl: 'a',
        fileSize: 0,
        downloadedBytes: 0,
        videoStreamSize: 0,
        audioSize: 10,
      );
      expect(t.combinedTotalSize, 0);
    });

    test('originalThreadCount prefers chunk count', () {
      expect(_task(threadCount: 8, chunks: [0.0, 0.0]).originalThreadCount, 2);
      expect(
        _task(threadCount: 8, chunks: const []).originalThreadCount,
        8,
      );
    });

    test('sanitizedChunks handles every length relationship', () {
      final equal = _task(threadCount: 2, chunks: [0.3, 0.6]);
      expect(equal.sanitizedChunks, [0.3, 0.6]);

      final empty = _task(
        threadCount: 2,
        chunks: const [],
        fileSize: 100,
        downloadedBytes: 50,
      );
      expect(empty.sanitizedChunks, [0.5, 0.5]);

      final fewer = _task(threadCount: 3, chunks: [0.2], fileSize: 100);
      expect(fewer.sanitizedChunks, [0.2, 0.2, 0.2]);

      final more = _task(threadCount: 2, chunks: [0.1, 0.2, 0.3, 0.4]);
      expect(more.sanitizedChunks, [0.5, 0.5]);
    });

    test('progress and indeterminate flags', () {
      expect(_task(status: DownloadStatus.completed).progress, 1.0);
      expect(_task(fileSize: 100, downloadedBytes: 25).progress,
          closeTo(0.25, 1e-9));
      final unknown = _task(fileSize: 0, downloadedBytes: 10);
      expect(unknown.progress, 0.0);
      expect(unknown.isIndeterminate, isTrue);
      expect(
          _task(fileSize: 100, downloadedBytes: 25).isIndeterminate, isFalse);
    });

    test('ytCombinedProgress returns null until a counterpart exists', () {
      expect(_task().ytCombinedProgress, isNull);
      final t = _task(
        mergedAudioUrl: 'a',
        fileSize: 100,
        audioSize: 100,
        downloadedBytes: 50,
        audioDownloadedBytes: 50,
      );
      expect(t.ytCombinedProgress, closeTo(0.5, 1e-9));
    });

    test('progressPercentString covers all branches', () {
      expect(_task(status: DownloadStatus.completed).progressPercentString,
          '100.0%');
      final torrent = _task(
        url: 'magnet:?xt=urn:btih:a',
        fileSize: 100,
        downloadedBytes: 50,
      );
      expect(torrent.progressPercentString, '50.0%');
      final unknown = _task(fileSize: 0, downloadedBytes: 1234);
      expect(unknown.progressPercentString, contains('KB'));
      final empty = _task(fileSize: 0, downloadedBytes: 0);
      expect(empty.progressPercentString, '—');
      expect(_task(fileSize: 100, downloadedBytes: 50).progressPercentString,
          '50.0%');
    });

    test('speedFormatted covers statuses', () {
      expect(_task(status: DownloadStatus.paused).speedFormatted, '0.0 KB/s');
      expect(
        _task(
          status: DownloadStatus.completed,
          url: 'magnet:?xt=urn:btih:a',
          seedingEnabled: true,
          speed: 1024,
        ).speedFormatted,
        contains('/s'),
      );
      expect(_task(speed: 0).speedFormatted, '0.0 KB/s');
      expect(_task(speed: 2048).speedFormatted, contains('/s'));
    });

    test('etaFormatted covers statuses and scales', () {
      expect(
        _task(
          status: DownloadStatus.completed,
          url: 'magnet:?xt=urn:btih:a',
          seedingEnabled: true,
        ).etaFormatted,
        'Seeding',
      );
      expect(_task(status: DownloadStatus.completed).etaFormatted, 'Finished');
      expect(_task(status: DownloadStatus.queued).etaFormatted, 'Queued');
      expect(
        _task(
          status: DownloadStatus.paused,
          scheduledAt: DateTime(2026),
        ).etaFormatted,
        'Scheduled',
      );
      expect(_task(status: DownloadStatus.paused).etaFormatted, 'Paused');
      expect(_task(status: DownloadStatus.failed).etaFormatted, 'Failed');
      expect(_task(eta: null).etaFormatted, '--');
      expect(_task(eta: 7200).etaFormatted, '2h 0m');
      expect(_task(eta: 125).etaFormatted, '2m 5s');
      expect(_task(eta: 30).etaFormatted, '30s');
    });

    test('elapsedFormatted covers statuses and scales', () {
      final base = DateTime(2026, 1, 1, 12);
      expect(
        _task(
          status: DownloadStatus.completed,
          createdAt: base,
          completedAt: base.add(const Duration(seconds: 30)),
        ).elapsedFormatted,
        '30s',
      );
      expect(
        _task(
          status: DownloadStatus.paused,
          createdAt: base,
          updatedAt: base.add(const Duration(minutes: 5)),
        ).elapsedFormatted,
        '5m 0s',
      );
      expect(
        _task(
          status: DownloadStatus.paused,
          createdAt: base,
          updatedAt: base.add(const Duration(hours: 3)),
        ).elapsedFormatted,
        '3h 0m',
      );
      expect(
        _task(
          status: DownloadStatus.paused,
          createdAt: base,
          updatedAt: base.add(const Duration(hours: 101)),
        ).elapsedFormatted,
        '4d 5h',
      );
      expect(
        _task(
          status: DownloadStatus.failed,
          createdAt: base,
          updatedAt: base.subtract(const Duration(seconds: 10)),
        ).elapsedFormatted,
        '0s',
      );
    });

    test('size getters cover known/unknown/completed', () {
      expect(_task(fileSize: 2048).sizeFormatted, isNotEmpty);
      expect(
          _task(
                  status: DownloadStatus.completed,
                  fileSize: 0,
                  downloadedBytes: 1024)
              .sizeFormatted,
          isNotEmpty);
      expect(_task(fileSize: 0, downloadedBytes: 0).sizeFormatted, 'Unknown');
      expect(
        _task(fileSize: 100, downloadedBytes: 500).downloadedSizeFormatted,
        isNotEmpty,
      );
      expect(_task(audioSize: 0).audioSizeFormatted, 'Unknown');
      expect(_task(audioSize: 100).audioSizeFormatted, isNotEmpty);
    });

    test('userFacingError sanitizes internal leakage', () {
      expect(
        _task(failureCategory: FailureCategory.diskFull).userFacingError,
        contains('storage'),
      );
      expect(_task(errorMessage: 'plain failure').userFacingError,
          'plain failure');
      expect(
        _task(errorMessage: 'Exception: secret details').userFacingError,
        'Download failed. Tap to retry.',
      );
      expect(
        _task(errorMessage: 'line1\nline2').userFacingError,
        'Download failed. Tap to retry.',
      );
      expect(
        _task(errorMessage: 'x' * 250).userFacingError,
        'Download failed. Tap to retry.',
      );
      expect(_task().userFacingError, 'Download failed. Tap to retry.');
    });

    test('core and progressSnapshot mirror the task', () {
      final t = _task(threadCount: 2, chunks: [0.5, 1.0]);
      expect(t.core.id, t.id);
      expect(t.progressRatio, closeTo(t.progress, 1e-9));
      expect(t.progressSnapshot.totalChunks, 2);
      expect(t.progressSnapshot.completedChunks, 1);
    });
  });

  group('copyWith', () {
    test('pins downloadedBytes to fileSize when completed', () {
      final completed = _task(fileSize: 1000, downloadedBytes: 0)
          .copyWith(status: DownloadStatus.completed);
      expect(completed.downloadedBytes, 1000);
    });

    test('clear flags reset individual fields', () {
      final base = _task(
        eta: 5,
        errorMessage: 'e',
        statusMessage: 'm',
        failureCategory: FailureCategory.network,
        recoveryHint: 'r',
        torrentFiles: [
          {'name': 'a', 'length': 1},
        ],
        mergedAudioUrl: 'a',
        mirrorUrls: ['https://m'],
        customHeaders: {'A': 'B'},
        playlistId: 'p',
        notes: 'n',
        cycleState: CycleState.downloading,
        torrentId: 1,
        infoHash: 'h',
      );
      final cleared = base.copyWith(
        clearEta: true,
        clearError: true,
        clearStatusMessage: true,
        clearFailureCategory: true,
        clearRecoveryHint: true,
        clearTorrentFiles: true,
        clearMergedAudioUrl: true,
        clearMirrorUrls: true,
        clearCustomHeaders: true,
        clearPlaylistId: true,
        clearNotes: true,
        clearCycleState: true,
        clearTorrentId: true,
        clearInfoHash: true,
      );
      expect(cleared.eta, isNull);
      expect(cleared.errorMessage, isNull);
      expect(cleared.statusMessage, isNull);
      expect(cleared.failureCategory, isNull);
      expect(cleared.recoveryHint, isNull);
      expect(cleared.torrentFiles, isNull);
      expect(cleared.mergedAudioUrl, isNull);
      expect(cleared.mirrorUrls, isNull);
      expect(cleared.customHeaders, isNull);
      expect(cleared.playlistId, isNull);
      expect(cleared.notes, isNull);
      expect(cleared.cycleState, isNull);
      expect(cleared.torrentId, isNull);
      expect(cleared.infoHash, isNull);
    });

    test('clearFileSize keeps size while still downloading with content', () {
      final downloading = _task(
        status: DownloadStatus.downloading,
        fileSize: 100,
      ).copyWith(clearFileSize: true);
      expect(downloading.fileSize, 100);

      final completed = _task(
        status: DownloadStatus.completed,
        fileSize: 100,
      ).copyWith(clearFileSize: true);
      expect(completed.fileSize, 0);
    });

    test('updated fields are applied', () {
      final updated = _task().copyWith(
        fileName: 'renamed.zip',
        speed: 123.0,
        speedLimitKbps: 99,
        seedingEnabled: true,
        priority: 2,
        audioThreadCount: 5,
      );
      expect(updated.fileName, 'renamed.zip');
      expect(updated.speed, 123.0);
      expect(updated.speedLimitKbps, 99);
      expect(updated.seedingEnabled, isTrue);
      expect(updated.priority, 2);
      expect(updated.audioThreadCount, 5);
    });

    test('audioProgress sanitizes NaN', () {
      final t = _task().copyWith(audioProgress: double.nan);
      expect(t.audioProgress, 0.0);
    });
  });

  group('transitions', () {
    test('illegal transitions are rejected and keep the status', () {
      final queued = _task(status: DownloadStatus.queued);
      final attempted = queued.transitionTo(DownloadStatus.completed);
      expect(attempted.status, DownloadStatus.queued);
    });

    test('isValidTransition delegates to the state machine', () {
      expect(
        DownloadTask.isValidTransition(
          DownloadStatus.queued,
          DownloadStatus.downloading,
        ),
        isTrue,
      );
    });

    test('legal transition applies modifiers', () {
      final t = _task(status: DownloadStatus.queued);
      final started = t.transitionTo(
        DownloadStatus.downloading,
        statusMessage: 'go',
        speed: 10,
      );
      expect(started.status, DownloadStatus.downloading);
      expect(started.statusMessage, 'go');
    });
  });
}
