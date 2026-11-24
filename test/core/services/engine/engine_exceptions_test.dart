import 'package:dmx/core/services/engine/engine_exceptions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('engine exceptions', () {
    test('IsolateSpawnTimeoutException default + custom message', () {
      expect(const IsolateSpawnTimeoutException().message,
          'Download engine failed to initialize. Please retry.');
      expect(const IsolateSpawnTimeoutException('boom').toString(),
          'IsolateSpawnTimeoutException: boom');
    });

    test('InsufficientStorageException default + custom message', () {
      expect(const InsufficientStorageException().message,
          contains('Not enough storage space'));
      expect(const InsufficientStorageException('no space').toString(),
          'InsufficientStorageException: no space');
    });

    test('InvalidPathException carries message', () {
      expect(const InvalidPathException('bad').toString(),
          'InvalidPathException: bad');
    });

    test('DownloadIntegrityException carries message', () {
      expect(const DownloadIntegrityException('corrupt').toString(),
          'DownloadIntegrityException: corrupt');
    });

    test('UrlExpiredException carries message and refresh flag', () {
      const e = UrlExpiredException('expired', refreshAllMirrors: true);
      expect(e.refreshAllMirrors, isTrue);
      expect(e.toString(), 'UrlExpiredException: expired');
      expect(const UrlExpiredException('x').refreshAllMirrors, isFalse);
    });

    test('TorrentEnginePauseException carries url', () {
      const e = TorrentEnginePauseException('paused', url: 'magnet:?x');
      expect(e.url, 'magnet:?x');
      expect(e.toString(), 'TorrentEnginePauseException: paused');
    });

    test('RangeUnsupportedException is an Exception', () {
      expect(RangeUnsupportedException(), isA<Exception>());
    });

    test('FileChangedOnServerException toString', () {
      expect(FileChangedOnServerException().toString(),
          'File changed on server. Restart required.');
    });

    test('TorrentStallException default + custom', () {
      expect(const TorrentStallException().message,
          'Torrent download stalled with no updates.');
      expect(const TorrentStallException('stuck').toString(),
          'TorrentStallException: stuck');
    });

    test('DelayQueueFullException default + custom', () {
      expect(const DelayQueueFullException().message,
          'Cancellable delay queue capacity exceeded.');
      expect(const DelayQueueFullException('full').toString(),
          'DelayQueueFullException: full');
    });

    test('StatePersistenceException carries directory', () {
      const e = StatePersistenceException('cannot write', directory: '/tmp');
      expect(e.directory, '/tmp');
      expect(e.toString(), 'StatePersistenceException: cannot write');
    });
  });
}
