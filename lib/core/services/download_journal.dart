import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

/// Append-only journal used to recover multi-thread download progress.
///
/// Hardened behavior:
/// - all writes are serialized
/// - `writeInit()` will not reset an existing non-empty journal
/// - journal is compacted automatically to avoid unbounded growth
class DownloadJournal {
  final String path;

  IOSink? _sink;
  bool _isOpen = false;

  int _approxBytes = 0;
  final int compactionThresholdBytes;

  final Lock _lock = Lock();

  DownloadJournal(this.path, {this.compactionThresholdBytes = 2 * 1024 * 1024});

  Future<void> open() async {
    await _lock.synchronized(() async {
      if (_isOpen) return;

      final file = File(path);

      if (await file.exists()) {
        try {
          _approxBytes = await file.length();
        } catch (_) {
          _approxBytes = 0;
        }
      } else {
        _approxBytes = 0;
      }

      _sink = file.openWrite(mode: FileMode.append);
      _isOpen = true;
    });
  }

  /// Writes an init event.
  ///
  /// Important:
  /// If the journal already contains data, this method intentionally does
  /// nothing. This prevents accidentally wiping recovered progress when the
  /// engine calls `writeInit()` after opening an existing journal.
  Future<void> writeInit(int threadCount, int totalSize) async {
    await _lock.synchronized(() async {
      _ensureOpen();

      if (_approxBytes > 0) {
        return;
      }

      final line = jsonEncode({
        't': 'init',
        'threads': threadCount,
        'total': totalSize,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });

      _sink!.writeln(line);
      await _sink!.flush();

      _approxBytes += line.length + 1;
    });
  }

  /// Records chunk progress.
  ///
  /// This is intentionally not flushed on every call to avoid disk thrashing.
  Future<void> recordChunkProgress(int index, int bytes) async {
    await _lock.synchronized(() {
      _ensureOpen();

      final line = jsonEncode({
        't': 'chunk',
        'i': index,
        'b': bytes,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });

      _sink!.writeln(line);
      _approxBytes += line.length + 1;
    });
  }

  /// Writes a durable checkpoint and flushes it.
  Future<void> writeCheckpoint(List<int> chunkProgress, int totalSize) async {
    await _lock.synchronized(() async {
      _ensureOpen();

      final line = jsonEncode({
        't': 'checkpoint',
        'chunks': chunkProgress,
        'total': totalSize,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });

      _sink!.writeln(line);
      await _sink!.flush();

      _approxBytes += line.length + 1;

      if (compactionThresholdBytes > 0 &&
          _approxBytes >= compactionThresholdBytes) {
        await _compactLocked(chunkProgress, totalSize);
      }
    });
  }

  /// Recovers the latest chunk progress from a journal file.
  static Future<List<int>?> recover(String journalPath) async {
    final file = File(journalPath);
    if (!await file.exists()) return null;

    List<int>? lastCheckpoint;
    int? threadCount;

    try {
      final lines = file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        try {
          final event = jsonDecode(trimmed) as Map<String, dynamic>;

          switch (event['t']) {
            case 'init':
              threadCount = event['threads'] as int?;
              lastCheckpoint = List.filled(threadCount ?? 0, 0);
              break;

            case 'checkpoint':
              final chunks = event['chunks'] as List<dynamic>?;
              if (chunks != null) {
                lastCheckpoint = chunks.map((e) => (e as num).toInt()).toList();
              }
              break;

            case 'chunk':
              if (lastCheckpoint != null) {
                final i = event['i'] as int?;
                final b = event['b'] as int?;

                if (i != null &&
                    b != null &&
                    i >= 0 &&
                    i < lastCheckpoint.length) {
                  lastCheckpoint[i] = b;
                }
              }
              break;
          }
        } catch (_) {
          // Ignore malformed lines.
        }
      }
    } catch (e) {
      debugPrint('[DownloadJournal] Recovery failed for $journalPath: $e');
      return null;
    }

    if (lastCheckpoint != null && lastCheckpoint.isEmpty) {
      debugPrint(
        '[DownloadJournal] Recovery for $journalPath yielded empty checkpoint. '
        'Treating as no journal.',
      );
      return null;
    }

    return lastCheckpoint;
  }

  Future<void> close() async {
    await _lock.synchronized(() async {
      await _closeLocked();
    });
  }

  Future<void> delete() async {
    await _lock.synchronized(() async {
      await _closeLocked();
    });

    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('[DownloadJournal] Failed to delete journal $path: $e');
    }
  }

  Future<void> _closeLocked() async {
    if (!_isOpen) return;

    _isOpen = false;

    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {
      // Ignore close errors.
    }

    _sink = null;
  }

  Future<void> _compactLocked(List<int> chunkProgress, int totalSize) async {
    try {
      await _sink?.flush();
      await _sink?.close();

      final tmp = File('$path.tmp');

      final initLine = jsonEncode({
        't': 'init',
        'threads': chunkProgress.length,
        'total': totalSize,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });

      final checkpointLine = jsonEncode({
        't': 'checkpoint',
        'chunks': chunkProgress,
        'total': totalSize,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });

      await tmp.writeAsString('$initLine\n$checkpointLine\n');
      await tmp.rename(path);

      _sink = File(path).openWrite(mode: FileMode.append);
      _isOpen = true;
      _approxBytes = initLine.length + checkpointLine.length + 2;
    } catch (e) {
      debugPrint('[DownloadJournal] Compaction failed for $path: $e');

      try {
        await File('$path.tmp').delete();
      } catch (_) {}

      // Best effort: try to reopen in append mode so writes can continue.
      try {
        _sink = File(path).openWrite(mode: FileMode.append);
        _isOpen = true;
      } catch (_) {
        _isOpen = false;
        _sink = null;
      }
    }
  }

  void _ensureOpen() {
    if (!_isOpen || _sink == null) {
      throw StateError('Journal not opened. Call open() first.');
    }
  }
}
