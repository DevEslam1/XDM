import 'package:dmx/core/domain/cycle_state.dart';
import 'package:dmx/core/services/engine/cycle_state_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => CycleStateResolver.clearCacheForTesting());

  group('CycleStateResolver.resolve', () {
    test('cancelled always resolves to paused', () {
      expect(
          CycleStateResolver.resolve(
              statusMessage: 'downloading', isCancelled: true),
          CycleState.paused);
      expect(CycleStateResolver.resolve(isCancelled: true), CycleState.paused);
    });

    test('null/blank status resolves to downloading', () {
      expect(CycleStateResolver.resolve(), CycleState.downloading);
      expect(CycleStateResolver.resolve(statusMessage: '   '),
          CycleState.downloading);
    });

    test('non-torrent message labels map to their cycle states', () {
      final cases = {
        'Fetching metadata': CycleState.fetchingMetadata,
        'downloading_metadata': CycleState.fetchingMetadata,
        'Allocating file': CycleState.allocating,
        'checking_files': CycleState.verifying,
        'Verifying data': CycleState.verifying,
        'Merging streams': CycleState.merging,
        'muxing': CycleState.merging,
        'seeding now': CycleState.seeding,
        'Refreshing links': CycleState.updatingLinks,
        'updating_links': CycleState.updatingLinks,
        'retrying connection': CycleState.retrying,
        'resuming download': CycleState.resuming,
        'starting up': CycleState.starting,
        'queued': CycleState.starting,
        'completed': CycleState.completed,
        'done': CycleState.completed,
        'finished': CycleState.completed,
        'paused by user': CycleState.paused,
        'cancelled': CycleState.paused,
        'stalled': CycleState.stalled,
        'no peers': CycleState.stalled,
        'error occurred': CycleState.failed,
        'failed to connect': CycleState.failed,
        'timeout': CycleState.failed,
      };
      cases.forEach((message, expected) {
        CycleStateResolver.clearCacheForTesting();
        expect(CycleStateResolver.resolve(statusMessage: message), expected,
            reason: message);
      });
    });

    test('unrecognized label falls back to downloading', () {
      expect(CycleStateResolver.resolve(statusMessage: 'zzz unknown zzz'),
          CycleState.downloading);
    });

    test('torrent direct map lookup normalizes spaces', () {
      expect(
          CycleStateResolver.resolve(
              statusMessage: 'Downloading Metadata', isTorrent: true),
          CycleState.fetchingMetadata);
    });

    test('torrent falls back to the raw (spaced) map key', () {
      expect(
          CycleStateResolver.resolve(
              statusMessage: 'waiting for counterpart stream…',
              isTorrent: true),
          CycleState.starting);
    });

    test('torrent falls back to fromLibtorrent for unknown labels', () {
      expect(
          CycleStateResolver.resolve(
              statusMessage: 'zzz totally unknown zzz', isTorrent: true),
          CycleState.stalled);
    });

    test('torrent falls back to fromLibtorrent for compound labels', () {
      expect(
          CycleStateResolver.resolve(
              statusMessage: 'stalled downloading', isTorrent: true),
          CycleState.stalled);
    });

    test('cache returns the same resolved value and grows then clears', () {
      CycleStateResolver.clearCacheForTesting();
      expect(CycleStateResolver.cacheSizeForTesting, 0);
      final first = CycleStateResolver.resolve(statusMessage: 'seeding');
      expect(CycleStateResolver.cacheSizeForTesting, 1);
      final second = CycleStateResolver.resolve(statusMessage: 'seeding');
      expect(identical(first, second), isTrue);
      CycleStateResolver.clearCacheForTesting();
      expect(CycleStateResolver.cacheSizeForTesting, 0);
    });
  });
}
