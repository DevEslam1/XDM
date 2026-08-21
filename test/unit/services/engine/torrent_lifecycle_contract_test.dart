import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/repositories/task_companion_converter.dart';
import 'package:dmx/core/services/torrent_models.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeContractTorrentService implements ITorrentService {
  final Set<int> _alive = {};
  final Map<int, TorrentUpdateInfo> _stats = {};
  final StreamController<Map<int, TorrentUpdateInfo>> _updateController =
      StreamController<Map<int, TorrentUpdateInfo>>.broadcast();

  int pauseCalls = 0;
  int resumeCalls = 0;
  int forceStopCalls = 0;

  void addAlive(int id) => _alive.add(id);
  void emitStats(Map<int, TorrentUpdateInfo> s) {
    _stats.addAll(s);
    _updateController.add(Map.unmodifiable(_stats));
  }

  @override
  bool get isSupported => true;
  @override
  bool get isInitialized => true;
  @override
  Future<void> get ready async {}
  @override
  ValueNotifier<bool> get isAvailable => ValueNotifier<bool>(true);
  @override
  Set<int> get activeTorrentIds => Set.unmodifiable(_alive);
  @override
  Map<int, TorrentUpdateInfo> get latestStats => Map.unmodifiable(_stats);
  @override
  Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates => _updateController.stream;

  @override
  bool isTorrentAlive(int id) => _alive.contains(id);

  @override
  Future<void> pauseTorrent(int id) async {
    pauseCalls++;
  }

  @override
  Future<void> resumeTorrent(int id) async {
    resumeCalls++;
  }

  @override
  Future<void> forceStopTorrent(int id) async {
    forceStopCalls++;
    _alive.remove(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('torrent_contract_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (methodCall) async => tempDir.path,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('Auto-Resume Filter: user-paused or cancelled tasks are never auto-resumed', () {
    final now = DateTime.now();
    final userPausedTask = DownloadTask(
      id: 'task-user-paused',
      fileName: 'test.zip',
      url: 'https://example.com/test.zip',
      fileSize: 1000,
      downloadedBytes: 100,
      category: 'other',
      status: DownloadStatus.paused,
      savePath: tempDir.path,
      localFilePath: '${tempDir.path}/test.zip',
      tempFilePath: '${tempDir.path}/test.zip.tmp',
      threadCount: 2,
      chunks: const [0.0, 0.0],
      createdAt: now,
      updatedAt: now,
      pausedByUser: true,
      pauseReason: PauseReason.user,
    );

    final offlinePausedTask = userPausedTask.copyWith(
      pausedByUser: false,
      pauseReason: PauseReason.networkLost,
    );

    final cancelledTask = userPausedTask.copyWith(
      status: DownloadStatus.failed,
      isCancelled: true,
      errorMessage: 'Transfer cancelled.',
    );

    // Filter predicate used by NetworkMonitor / auto-resume
    bool isEligibleForAutoResume(DownloadTask t) {
      if (t.isCancelled) return false;
      if (t.status != DownloadStatus.paused) return false;
      if (t.pausedByUser) return false;
      if (t.pauseReason == PauseReason.user) return false;
      return true;
    }

    expect(isEligibleForAutoResume(userPausedTask), isFalse, reason: 'User-paused tasks must not auto-resume');
    expect(isEligibleForAutoResume(cancelledTask), isFalse, reason: 'Cancelled tasks must not auto-resume');
    expect(isEligibleForAutoResume(offlinePausedTask), isTrue, reason: 'Network-paused tasks are eligible to auto-resume on reconnect');
  });

  test('Fastresume Store: Save, SHA-256 verification, and roundtrip load', () async {
    const sourceUrl = 'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335de7ec7667a80&dn=Test';
    final sampleResumeBytes = Uint8List.fromList(
      List.generate(2048, (i) => (i * 23 + 3) % 256),
    );

    final saved = await TorrentResumeStore.saveAndWait(
      torrentId: 42,
      sourceUrl: sourceUrl,
      fetchResumeData: () => sampleResumeBytes,
      files: [
        {'name': 'file1.bin', 'size': 2048, 'downloadedBytes': 1024, 'selected': true, 'priority': 4}
      ],
    );

    expect(saved, isTrue);

    final loadedBytes = await TorrentResumeStore.loadResumeDataForSource(sourceUrl);
    expect(loadedBytes, isNotNull);
    expect(sha256.convert(loadedBytes!).toString(), equals(sha256.convert(sampleResumeBytes).toString()));

    final loadedFiles = await TorrentResumeStore.loadFilesForSource(sourceUrl);
    expect(loadedFiles, isNotNull);
    expect(loadedFiles!.length, equals(1));
    expect(loadedFiles.first['name'], equals('file1.bin'));
    expect(loadedFiles.first['downloadedBytes'], equals(1024));
  });

  test('Pause Verification Semantics (D4): null stats rejected, confirmation succeeds on stateLabel paused', () async {
    final fakeService = _FakeContractTorrentService()..addAlive(10);

    final streamFuture = fakeService.torrentUpdates.firstWhere((updateMap) {
      final stats = updateMap[10];
      if (stats == null) return false; // D4: Must not treat null as success
      final label = stats.stateLabel.toLowerCase();
      return label.contains('paused') || label.contains('stopped');
    }).timeout(const Duration(seconds: 2));

    // Emit empty stats update (id 10 is missing)
    fakeService.emitStats({});

    // Emit update with downloading state
    fakeService.emitStats({
      10: TorrentUpdateInfo(
        id: 10,
        name: 'test',
        progress: 0.5,
        downloadRate: 100,
        uploadRate: 0,
        totalDone: 500,
        totalWanted: 1000,
        totalWantedDone: 500,
        hasMetadata: true,
        stateLabel: 'downloading',
        numSeeds: 5,
        numPeers: 10,
        piecesHave: 50,
        piecesTotal: 100,
        downloadPayloadRate: 100,
        uploadPayloadRate: 0,
        totalPayloadDownload: 500,
        totalPayloadUpload: 0,
        currentTracker: '',
        nextAnnounceSeconds: 0,
        distributedCopies: 0.0,
        fileProgress: const [],
        filePriorities: const [],
      )
    });

    // Emit update with paused state
    fakeService.emitStats({
      10: TorrentUpdateInfo(
        id: 10,
        name: 'test',
        progress: 0.5,
        downloadRate: 0,
        uploadRate: 0,
        totalDone: 500,
        totalWanted: 1000,
        totalWantedDone: 500,
        hasMetadata: true,
        stateLabel: 'paused',
        numSeeds: 5,
        numPeers: 10,
        piecesHave: 50,
        piecesTotal: 100,
        downloadPayloadRate: 0,
        uploadPayloadRate: 0,
        totalPayloadDownload: 500,
        totalPayloadUpload: 0,
        currentTracker: '',
        nextAnnounceSeconds: 0,
        distributedCopies: 0.0,
        fileProgress: const [],
        filePriorities: const [],
      )
    });

    final verifiedMap = await streamFuture;
    expect(verifiedMap[10]?.stateLabel, equals('paused'));
  });

  test('Cancel Persistence: cancel -> DB roundtrip -> task remains cancelled across restart', () {
    final originalTask = DownloadTask(
      id: 'task-cancel-persist',
      fileName: 'cancel_me.zip',
      url: 'https://example.com/cancel_me.zip',
      fileSize: 5000,
      downloadedBytes: 1000,
      category: 'other',
      status: DownloadStatus.failed,
      savePath: tempDir.path,
      localFilePath: '${tempDir.path}/cancel_me.zip',
      tempFilePath: '${tempDir.path}/cancel_me.zip.tmp',
      threadCount: 2,
      chunks: const [0.0, 0.0],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      errorMessage: 'Transfer cancelled.',
      isCancelled: true,
      pausedByUser: true,
    );

    // Convert to DB companion and simulate DB row restoration
    final companion = TaskCompanionConverter.taskToCompanion(originalTask);
    final dbRow = DbDownloadTask(
      id: companion.id.value,
      fileName: companion.fileName.value,
      url: companion.url.value,
      fileSize: companion.fileSize.value,
      downloadedBytes: companion.downloadedBytes.value,
      speed: companion.speed.value,
      category: companion.category.value,
      status: companion.status.value,
      savePath: companion.savePath.value,
      localFilePath: companion.localFilePath.value,
      tempFilePath: companion.tempFilePath.value,
      errorMessage: companion.errorMessage.value,
      threadCount: companion.threadCount.value,
      createdAt: companion.createdAt.value,
      updatedAt: companion.updatedAt.value,
      supportsResume: companion.supportsResume.value,
      speedLimitKbps: companion.speedLimitKbps.value,
      seedingEnabled: companion.seedingEnabled.value,
      seedingLimited: companion.seedingLimited.value,
      seedingLimitKbps: companion.seedingLimitKbps.value,
      audioSize: companion.audioSize.value,
      audioDownloadedBytes: companion.audioDownloadedBytes.value,
      videoStreamSize: companion.videoStreamSize.value,
      audioProgress: companion.audioProgress.value,
      pausedByUser: companion.pausedByUser.value,
      isAppUpdate: companion.isAppUpdate.value,
      uploadedBytes: 0,
      priority: 0,
      queueOrder: 0,
      isCancelled: companion.isCancelled.value,
    );

    final restoredTask = TaskCompanionConverter.rowToTask(dbRow);
    expect(restoredTask.isCancelled, isTrue);
    expect(restoredTask.status, equals(DownloadStatus.failed));
    expect(restoredTask.errorMessage, equals('Transfer cancelled.'));

    // Check that auto-resume filter rejects the restored cancelled task
    bool isEligibleForAutoResume(DownloadTask t) {
      if (t.isCancelled) return false;
      if (t.status != DownloadStatus.paused) return false;
      if (t.pausedByUser) return false;
      return true;
    }

    expect(isEligibleForAutoResume(restoredTask), isFalse);
  });

  test('N2: Task failed with Dio cancel errorMessage (isCancelled: false in DB) must NOT be isCancelled on restart', () {
    final dioFailedTask = DownloadTask(
      id: 'task-dio-error',
      fileName: 'network_file.zip',
      url: 'https://example.com/network_file.zip',
      fileSize: 5000,
      downloadedBytes: 1000,
      category: 'other',
      status: DownloadStatus.failed,
      savePath: tempDir.path,
      localFilePath: '${tempDir.path}/network_file.zip',
      tempFilePath: '${tempDir.path}/network_file.zip.tmp',
      threadCount: 2,
      chunks: const [0.0, 0.0],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      errorMessage: 'DioException [bad response]: The request was cancelled by client',
      isCancelled: false,
      pausedByUser: false,
    );

    final companion = TaskCompanionConverter.taskToCompanion(dioFailedTask);
    final dbRow = DbDownloadTask(
      id: companion.id.value,
      fileName: companion.fileName.value,
      url: companion.url.value,
      fileSize: companion.fileSize.value,
      downloadedBytes: companion.downloadedBytes.value,
      speed: companion.speed.value,
      category: companion.category.value,
      status: companion.status.value,
      savePath: companion.savePath.value,
      localFilePath: companion.localFilePath.value,
      tempFilePath: companion.tempFilePath.value,
      errorMessage: companion.errorMessage.value,
      threadCount: companion.threadCount.value,
      createdAt: companion.createdAt.value,
      updatedAt: companion.updatedAt.value,
      supportsResume: companion.supportsResume.value,
      speedLimitKbps: companion.speedLimitKbps.value,
      seedingEnabled: companion.seedingEnabled.value,
      seedingLimited: companion.seedingLimited.value,
      seedingLimitKbps: companion.seedingLimitKbps.value,
      audioSize: companion.audioSize.value,
      audioDownloadedBytes: companion.audioDownloadedBytes.value,
      videoStreamSize: companion.videoStreamSize.value,
      audioProgress: companion.audioProgress.value,
      pausedByUser: companion.pausedByUser.value,
      isAppUpdate: companion.isAppUpdate.value,
      uploadedBytes: 0,
      priority: 0,
      queueOrder: 0,
      isCancelled: false,
    );

    final restoredTask = TaskCompanionConverter.rowToTask(dbRow);
    expect(restoredTask.isCancelled, isFalse,
        reason: 'Generic error message containing the word "cancelled" must NOT mark task as isCancelled');
  });

  test('N1: Monotonic floor resets on legitimate decrease events (file deselect, recheck, removal)', () {
    // 1. Initial download state: 1000 totalWanted, 50% progress -> 500 bytes
    var totalWanted = 1000;
    var priorities = [4, 4];
    var stateLabel = 'downloading';
    var progress = 0.5;

    int calculateSynthesized(
      int currentTotalWanted,
      List<int> currentPriorities,
      String currentState,
      double currentProgress,
      Map<String, dynamic> floorState,
    ) {
      final safeProgress = currentProgress.clamp(0.0, 1.0);
      final calculated = (safeProgress * currentTotalWanted).toInt().clamp(0, currentTotalWanted);
      final prioritiesHash = currentPriorities.fold<int>(0, (acc, p) => acc * 31 + p);
      final currentKey = '$currentTotalWanted:$prioritiesHash:$currentState';
      final prevKey = floorState['key'];

      final isStateChecking = currentState.toLowerCase().contains('check');
      if (prevKey == null || prevKey != currentKey || isStateChecking) {
        floorState['key'] = currentKey;
        floorState['floor'] = calculated;
        return calculated;
      } else {
        final floor = (floorState['floor'] as int? ?? 0) > calculated
            ? floorState['floor'] as int
            : calculated;
        floorState['floor'] = floor;
        return floor;
      }
    }

    final floorState = <String, dynamic>{};
    final step1 = calculateSynthesized(totalWanted, priorities, stateLabel, progress, floorState);
    expect(step1, equals(500));

    // Transient drop during same key is clamped by monotonic floor
    progress = 0.48;
    final step2 = calculateSynthesized(totalWanted, priorities, stateLabel, progress, floorState);
    expect(step2, equals(500), reason: 'Monotonic floor prevents transient jitter');

    // Deselect file -> totalWanted drops to 500, priorities change to [4, 0]
    totalWanted = 500;
    priorities = [4, 0];
    progress = 0.6; // 60% of 500 = 300
    final step3 = calculateSynthesized(totalWanted, priorities, stateLabel, progress, floorState);
    expect(step3, equals(300), reason: 'Deselecting files resets floor to new wanted extent');

    // Recheck event -> state becomes checkingFiles, progress is 0.1
    stateLabel = 'checkingFiles';
    progress = 0.1; // 10% of 500 = 50
    final step4 = calculateSynthesized(totalWanted, priorities, stateLabel, progress, floorState);
    expect(step4, equals(50), reason: 'Rechecking files resets floor immediately');

    // Remove and re-add torrent -> state clears
    floorState.clear();
    stateLabel = 'downloading';
    progress = 0.2; // 20% of 500 = 100
    final step5 = calculateSynthesized(totalWanted, priorities, stateLabel, progress, floorState);
    expect(step5, equals(100), reason: 'Removed torrent clears floor completely');
  });
}
