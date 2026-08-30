import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// B5 regression: pauseTorrent used to wait for a 'paused' status tick INSIDE
/// _torrentLock.synchronized, while the status producer adds its ticks from
/// inside the same lock — so the wait could only ever match pre-buffered
/// events, burning 5s ×3 attempts and serially blocking every other locked
/// operation (including forceStopTorrent).
///
/// With a native that never emits a paused tick, force-stop must still be
/// reachable promptly: the pause wait now happens outside the lock, so a
/// concurrent forceStopTorrent acquires it immediately, releases the waiter,
/// and the pause completes within a fraction of the old 15s worst case.
class _SilentPauseNative extends FakeTorrentNative {
  final List<int> pauseCalls = [];

  @override
  Future<void> pauseTorrent(int id, {bool graceful = true}) async {
    pauseCalls.add(id);
    // Never mark the torrent paused and never emit a status tick: the worst
    // case the 1.9.2 bridge can produce.
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'B5: pauseTorrent does not starve the lock; force-stop completes within budget',
      () async {
    final native = _SilentPauseNative();
    TorrentService.setNativeForTesting(native);
    addTearDown(() async {
      await TorrentService.dispose();
    });

    native.seedTorrent(
      id: 7,
      name: 'stuck.bin',
      files: [
        const NativeFileInfo(
          index: 0,
          name: 'stuck.bin',
          path: '/downloads/stuck.bin',
          size: 1000,
          isStreamable: false,
        ),
      ],
    );
    expect(TorrentService.isTorrentAlive(7), isTrue);

    // Start the graceful pause; it can never observe a paused tick.
    final pauseFuture = TorrentService.pauseTorrent(7);

    // Give it time to enter its wait. With the bug, it holds _torrentLock
    // for the whole 3×5s timeout loop from this point on.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(native.pauseCalls, contains(7));

    // Force-stop must acquire the lock promptly — this is the op the old
    // implementation serially blocked.
    final stopWatch = Stopwatch()..start();
    await TorrentService.forceStopTorrent(7).timeout(
      const Duration(seconds: 3),
      onTimeout: () => fail(
        'forceStopTorrent starved behind pauseTorrent — the pause wait is '
        'still holding _torrentLock',
      ),
    );
    stopWatch.stop();
    expect(stopWatch.elapsed, lessThan(const Duration(seconds: 3)));

    // And the pause itself must finish long before the old 15s worst case:
    // the released waiter lets it confirm and move on.
    await pauseFuture.timeout(
      const Duration(seconds: 8),
      onTimeout: () => fail('pauseTorrent did not complete after force-stop'),
    );
    expect(native.pauseCalls.length, greaterThanOrEqualTo(1));
  });
}
