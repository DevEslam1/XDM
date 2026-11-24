import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/transfer_state.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadCommand _base() => const DownloadCommand(
      taskId: 't1',
      url: 'https://example.com/f.zip',
      punyUrl: 'https://example.com/f.zip',
      tempFilePath: '/tmp/f.zip.dmxpart',
      localFilePath: '/tmp/f.zip',
      knownFileSize: 100,
      supportsResume: true,
      threadCount: 4,
    );

void main() {
  group('EngineMessageType', () {
    test('fromWire resolves every enum name', () {
      for (final t in EngineMessageType.values) {
        expect(EngineMessageType.fromWire(t.name), t);
      }
    });

    test('fromWire rejects non-string and unknown values', () {
      expect(EngineMessageType.fromWire(null), isNull);
      expect(EngineMessageType.fromWire(42), isNull);
      expect(EngineMessageType.fromWire('nope'), isNull);
    });
  });

  group('ChunkResult', () {
    test('holds fields with defaults', () {
      final chunk = ChunkState(start: 0, end: 10, downloaded: 5);
      final result =
          ChunkResult(chunk: ChunkState(start: 0, end: 1), success: true);
      expect(result.attempts, 1);
      expect(result.error, isNull);
      expect(result.chunk, isA<ChunkState>());
      expect(chunk.downloaded, 5);
    });
  });

  group('DownloadCommand', () {
    test('toMap/fromMap round-trips the core fields', () {
      final cmd = _base();
      final map = cmd.toMap();
      final restored = DownloadCommand.fromMap(map);
      expect(restored.taskId, cmd.taskId);
      expect(restored.url, cmd.url);
      expect(restored.knownFileSize, 100);
      expect(restored.supportsResume, isTrue);
      expect(restored.threadCount, 4);
      expect(restored.diskWriteBatching, isTrue);
      expect(restored.stalledTimeoutMinutes, 5);
      expect(restored.resumeIntegrityCheck, isTrue);
    });

    test('speedLimit/activeCount aliases win over initial defaults', () {
      const cmd = DownloadCommand(
        taskId: 't',
        url: 'u',
        punyUrl: 'u',
        tempFilePath: 't',
        localFilePath: 'l',
        knownFileSize: 0,
        supportsResume: false,
        threadCount: 1,
        speedLimit: 123,
        activeCount: 7,
      );
      expect(cmd.initialSpeedLimit, 123);
      expect(cmd.initialActiveCount, 7);
      expect(cmd.speedLimitKbps, 123);
    });

    test('toMap emits optional fields when present', () {
      const cmd = DownloadCommand(
        taskId: 't',
        url: 'u',
        punyUrl: 'u',
        tempFilePath: 't',
        localFilePath: 'l',
        knownFileSize: 0,
        supportsResume: false,
        threadCount: 1,
        customHeaders: {'X-A': 'b'},
        ytStreamKind: YtStreamKind.audio,
        ytCounterpartSize: 10,
        ytCounterpartDownloadedBytes: 5,
        ytCounterpartTaskId: 'cp',
      );
      final map = cmd.toMap();
      expect(map['ytStreamKind'], 'audio');
      expect(map['ytCounterpartSize'], 10);
      expect(map['customHeaders'], {'X-A': 'b'});
      final restored = DownloadCommand.fromMap(map);
      expect(restored.ytStreamKind, YtStreamKind.audio);
      expect(restored.customHeaders, {'X-A': 'b'});
    });

    test('fromMap tolerates missing optionals and bad ytStreamKind', () {
      final restored = DownloadCommand.fromMap(const {
        'taskId': 't',
        'url': 'u',
        'punyUrl': 'u',
        'tempFilePath': 'tp',
        'localFilePath': 'lp',
        'ytStreamKind': 'bogus',
      });
      expect(restored.knownFileSize, 0);
      expect(restored.supportsResume, isFalse);
      expect(restored.threadCount, 1);
      expect(restored.throttleFactor, 1.0);
      expect(restored.ytStreamKind, YtStreamKind.combined);
    });

    test('fromMap parses customHeaders map values to strings', () {
      final restored = DownloadCommand.fromMap(const {
        'taskId': 't',
        'url': 'u',
        'punyUrl': 'u',
        'tempFilePath': 'tp',
        'localFilePath': 'lp',
        'customHeaders': {1: 2},
      });
      expect(restored.customHeaders, {'1': '2'});
    });
  });

  test('SpeedSample stores pair', () {
    final s = SpeedSample(100, 2048);
    expect(s.timestampMs, 100);
    expect(s.bytes, 2048);
  });
}
