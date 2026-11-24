import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:dmx/core/utils/torrent_id_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const hexHash = 'da39a3ee5e6b4b0d3255bfef95601890afd80709';

  late FakeTorrentNative fakeNative;

  setUp(() {
    fakeNative = FakeTorrentNative();
    TorrentService.setNativeForTesting(fakeNative);
  });

  tearDown(() async {
    await TorrentService.dispose();
  });

  Future<void> seed(int id) async {
    fakeNative.seedTorrent(
      id: id,
      name: 'torrent_$id',
      files: const [
        NativeFileInfo(
          index: 0,
          name: 'f.bin',
          path: 'f.bin',
          size: 100,
          isStreamable: false,
        ),
      ],
    );
    // Let the status stream listener populate TorrentService.latestStats.
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  group('TorrentIdResolver.resolve', () {
    test('returns null for a null task', () {
      expect(TorrentIdResolver.resolve(null), isNull);
    });

    test('prefers a stored torrentId the live session recognises', () async {
      await seed(5);
      final task = createTestTask(
        id: 'task-a',
        url: 'https://example.com/movie.torrent',
      ).copyWith(torrentId: 5);
      expect(TorrentIdResolver.resolve(task), 5);
    });

    test('falls through a stale candidate to one the session knows', () async {
      await seed(5);
      final task = createTestTask(id: 'task-b', url: '').copyWith(torrentId: 3);
      expect(
        TorrentIdResolver.resolve(task, providerMap: {'task-b': 5}),
        5,
      );
    });

    test('returns the first candidate when the session knows none of them',
        () async {
      await seed(5);
      final task = createTestTask(id: 'task-c', url: '').copyWith(torrentId: 9);
      expect(TorrentIdResolver.resolve(task), 9);
    });

    test('uses the numeric task id only when the session holds it', () async {
      await seed(7);
      final task = createTestTask(id: '7', url: '');
      expect(TorrentIdResolver.resolve(task), 7);
    });

    test('returns null when no candidate is live', () async {
      await seed(7);
      final task = createTestTask(id: '99', url: '');
      expect(TorrentIdResolver.resolve(task), isNull);
    });

    test('ignores negative provider ids and yields null', () {
      final task = createTestTask(id: 'task-d', url: '');
      expect(
        TorrentIdResolver.resolve(task, providerMap: {'task-d': -1}),
        isNull,
      );
    });
  });

  group('TorrentIdResolver.resolveFromSource', () {
    test('handles null, empty, and unregistered sources', () {
      expect(TorrentIdResolver.resolveFromSource(null), isNull);
      expect(TorrentIdResolver.resolveFromSource(''), isNull);
      expect(
        TorrentIdResolver.resolveFromSource('https://example.com/a.torrent'),
        isNull,
      );
    });

    test('parses a magnet but finds no matching handle', () {
      expect(
        TorrentIdResolver.resolveFromSource('magnet:?xt=urn:btih:$hexHash'),
        isNull,
      );
    });
  });
}
