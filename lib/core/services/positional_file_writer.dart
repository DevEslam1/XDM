import 'dart:io';
import 'dart:typed_data';

import 'package:synchronized/synchronized.dart';

/// I/O failure inside the writer. The engine maps message heuristics
/// (ENOSPC / "space") onto [InsufficientStorageException].
class PositionalFileWriterException implements Exception, StateError {
  const PositionalFileWriterException(this.message);
  @override
  final String message;
  @override
  StackTrace? get stackTrace => null;
  @override
  String toString() => 'PositionalFileWriterException: $message';
}

/// Random-access writer for chunked downloads.
///
/// Contract:
///  - `open()` creates and PRE-ALLOCATES the file to `totalSize`. Because the
///    file length is therefore meaningless until complete, progress must
///    always be read from the TransferState document, never from `length()`.
///  - `openForResume()` never truncates existing data; it only extends or
///    trims the container to `totalSize`.
///  - All operations are serialized; writes outside the declared total are
///    rejected so a buggy caller can never corrupt the container.
class PositionalFileWriter {
  PositionalFileWriter._(
    this._raf,
    this.path,
    this.totalSize,
    this.threadCount,
  ) : _highWater = List<int>.filled(threadCount < 1 ? 1 : threadCount, 0);

  final RandomAccessFile _raf;
  final String path;
  final int totalSize;
  final int threadCount;
  final Lock _lock = Lock();
  final List<int> _highWater;
  bool _closed = false;

  static Future<PositionalFileWriter> open(
    String path, {
    required int totalSize,
    required int threadCount,
    int? bufferSize,
  }) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      final raf = await file.open(mode: FileMode.write);
      if (totalSize > 0) {
        await raf.truncate(totalSize);
      }
      return PositionalFileWriter._(raf, path, totalSize, threadCount);
    } catch (e) {
      throw PositionalFileWriterException('open failed: $e');
    }
  }

  static Future<PositionalFileWriter> openForResume(
    String path, {
    required int threadCount,
    int? totalSize,
    int? bufferSize,
  }) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      // FileMode.append: read+write, preserves existing content or creates new.
      final raf = await file.open(mode: FileMode.append);
      if (totalSize != null && totalSize > 0) {
        final len = await raf.length();
        if (len != totalSize) {
          await raf.truncate(totalSize);
        }
      }
      return PositionalFileWriter._(raf, path, totalSize ?? 0, threadCount);
    } on PositionalFileWriterException {
      rethrow;
    } catch (e) {
      throw PositionalFileWriterException('openForResume failed: $e');
    }
  }

  /// Writes [data] at [absolutePosition]. Throws when the write would fall
  /// outside the declared total — the scheduler must never produce that, and
  /// failing loudly is cheaper than a silently corrupted file.
  Future<void> write(
      int threadIndex, int absolutePosition, Uint8List data) async {
    await _lock.synchronized(() async {
      _checkOpen();
      if (data.isEmpty) return;
      if (absolutePosition < 0) {
        throw const PositionalFileWriterException('negative write position');
      }
      if (totalSize > 0 && absolutePosition + data.length > totalSize) {
        throw PositionalFileWriterException(
            'write exceeds declared total: pos=$absolutePosition '
            'len=${data.length} total=$totalSize');
      }
      try {
        await _raf.setPosition(absolutePosition);
        await _raf.writeFrom(data);
      } catch (e) {
        throw PositionalFileWriterException('write failed: $e');
      }
      if (threadIndex >= 0 && threadIndex < _highWater.length) {
        final end = absolutePosition + data.length;
        if (end > _highWater[threadIndex]) _highWater[threadIndex] = end;
      }
    });
  }

  /// Durability barrier. [threadIndex] is accepted for API compatibility;
  /// the underlying handle is shared, so every flush is global.
  Future<void> flush([int threadIndex = -1]) async {
    await _lock.synchronized(() async {
      _checkOpen();
      try {
        await _raf.flush();
      } catch (e) {
        throw PositionalFileWriterException('flush failed: $e');
      }
    });
  }

  Future<void> flushAll() => flush();

  /// Reads a byte range back from disk (resume spot-checks).
  Future<Uint8List> readRange(int start, int length) async {
    return _lock.synchronized(() async {
      _checkOpen();
      try {
        await _raf.setPosition(start);
        final bytes = await _raf.read(length);
        return bytes;
      } catch (e) {
        throw PositionalFileWriterException('readRange failed: $e');
      }
    });
  }

  Future<int> length() async {
    return _lock.synchronized(() async {
      _checkOpen();
      return _raf.length();
    });
  }

  Future<int> fileSize() => length();

  Future<void> close() async {
    await _lock.synchronized(() async {
      if (_closed) return;
      _closed = true;
      try {
        await _raf.close();
      } catch (_) {}
    });
  }

  void _checkOpen() {
    if (_closed) {
      throw const PositionalFileWriterException('writer is closed');
    }
  }
}
