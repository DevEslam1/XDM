import 'dart:io';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';

import 'torrent_models.dart';

enum DiskIoMode { ssd, hdd, emmc }

/// Phase 2 & 8: Disk I/O, Storage Type & Piece Size Optimization
class TorrentDiskManager {
  /// Adaptive disk cache size in MB based on available platform memory.
  static int optimalCacheSizeMb() {
    final totalRam = getTotalRamMb();
    if (totalRam <= 2048) return 64; // 2GB RAM -> 64MB cache
    if (totalRam <= 4096) return 128; // 4GB RAM -> 128MB cache
    if (totalRam <= 6144) return 256; // 6GB RAM -> 256MB cache
    return 512; // 8GB+ RAM -> 512MB cache
  }

  /// Per-torrent disk I/O mode based on storage heuristics.
  static DiskIoMode optimalDiskIoMode() {
    if (kIsWeb) return DiskIoMode.ssd;
    if (Platform.isAndroid || Platform.isIOS) {
      return DiskIoMode.emmc;
    }
    if (Platform.isLinux) {
      try {
        final rotational = File('/sys/block/sda/queue/rotational');
        if (rotational.existsSync()) {
          final content = rotational.readAsStringSync().trim();
          if (content == '0') return DiskIoMode.ssd;
          if (content == '1') return DiskIoMode.hdd;
        }
        if (Directory('/sys/block/mmcblk0').existsSync()) {
          return DiskIoMode.emmc;
        }
      } catch (e, st) {
        LoggingService.logger('TorrentDiskManager')
            .warning('Operation failed', e, st);
      }
    }
    return DiskIoMode.ssd;
  }

  /// Optimal write coalescing chunk bytes to minimize disk IOPS.
  static int coalesceWriteBytes(DiskIoMode mode) {
    switch (mode) {
      case DiskIoMode.ssd:
        return 64 * 1024; // 64KB coalesce
      case DiskIoMode.emmc:
        return 256 * 1024; // 256KB coalesce (crucial for budget Android eMMC)
      case DiskIoMode.hdd:
        return 512 * 1024; // 512KB coalesce
    }
  }

  /// Read cache size in MB per torrent file size.
  static int readCacheSizeMb(int fileSizeMb) {
    if (fileSizeMb > 4096) return 64; // Large > 4GB: 64MB
    if (fileSizeMb > 1024) return 32; // Medium > 1GB: 32MB
    return 16; // Small: 16MB
  }

  /// Auto-select optimal piece size in bytes based on file size (Phase 8).
  static int optimalPieceSize(int fileSize) {
    if (fileSize < 100 * 1024 * 1024) return 256 * 1024; // < 100MB: 256KB
    if (fileSize < 1024 * 1024 * 1024) return 512 * 1024; // < 1GB: 512KB
    if (fileSize < 5 * 1024 * 1024 * 1024) return 1024 * 1024; // < 5GB: 1MB
    return 2 * 1024 * 1024; // > 5GB: 2MB
  }

  /// Checks whether files in a torrent contain streaming video candidates.
  static bool hasStreamingVideo(List<TorrentFileItem> files) {
    return files.any((f) =>
        f.size > 50 * 1024 * 1024 && // > 50MB
        (f.name.endsWith('.mp4') ||
            f.name.endsWith('.mkv') ||
            f.name.endsWith('.avi') ||
            f.name.endsWith('.webm') ||
            f.name.endsWith('.mov') ||
            f.name.endsWith('.ts')));
  }

  /// Estimates available total RAM in MB across platforms.
  static int getTotalRamMb() {
    try {
      if (Platform.isLinux || Platform.isAndroid) {
        final meminfo = File('/proc/meminfo');
        if (meminfo.existsSync()) {
          final lines = meminfo.readAsLinesSync();
          for (final line in lines) {
            if (line.startsWith('MemTotal:')) {
              final parts = line.split(RegExp(r'\s+'));
              if (parts.length >= 2) {
                final kb = int.tryParse(parts[1]);
                if (kb != null) return kb ~/ 1024;
              }
            }
          }
        }
      }
      return 4096; // Fallback default: 4GB
    } catch (e, st) {
      LoggingService.logger('TorrentDiskManager')
          .warning('Operation failed with fallback', e, st);
      return 4096;
    }
  }
}
