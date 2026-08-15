import 'package:dmx/core/services/torrent_disk_manager.dart';
import 'package:dmx/core/services/torrent_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TorrentDiskManager Unit Tests (Phase 2 & 8)', () {
    test('optimalCacheSizeMb returns reasonable RAM cache allocation', () {
      final cacheMb = TorrentDiskManager.optimalCacheSizeMb();
      expect(cacheMb, isIn([64, 128, 256, 512]));
    });

    test('coalesceWriteBytes scales per DiskIoMode', () {
      expect(TorrentDiskManager.coalesceWriteBytes(DiskIoMode.ssd), 64 * 1024);
      expect(TorrentDiskManager.coalesceWriteBytes(DiskIoMode.emmc), 256 * 1024);
      expect(TorrentDiskManager.coalesceWriteBytes(DiskIoMode.hdd), 512 * 1024);
    });

    test('readCacheSizeMb scales with file size', () {
      expect(TorrentDiskManager.readCacheSizeMb(500), 16);
      expect(TorrentDiskManager.readCacheSizeMb(2000), 32);
      expect(TorrentDiskManager.readCacheSizeMb(6000), 64);
    });

    test('optimalPieceSize scales cleanly with total file bytes', () {
      expect(TorrentDiskManager.optimalPieceSize(50 * 1024 * 1024), 256 * 1024);
      expect(TorrentDiskManager.optimalPieceSize(500 * 1024 * 1024), 512 * 1024);
      expect(TorrentDiskManager.optimalPieceSize(2 * 1024 * 1024 * 1024), 1024 * 1024);
      expect(TorrentDiskManager.optimalPieceSize(10 * 1024 * 1024 * 1024), 2 * 1024 * 1024);
    });

    test('hasStreamingVideo accurately detects video extensions', () {
      final nonVideo = [
        TorrentFileItem(index: 0, name: 'document.pdf', size: 100 * 1024 * 1024),
        TorrentFileItem(index: 1, name: 'archive.zip', size: 200 * 1024 * 1024),
      ];
      expect(TorrentDiskManager.hasStreamingVideo(nonVideo), isFalse);

      final video = [
        TorrentFileItem(index: 0, name: 'movie.mkv', size: 800 * 1024 * 1024),
      ];
      expect(TorrentDiskManager.hasStreamingVideo(video), isTrue);
    });
  });
}
