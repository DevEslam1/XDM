import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

/// Buffered positional writer for multi-thread downloads.
///
/// Hardened behavior:
/// - detects non-contiguous writes and flushes before continuing
/// - safer resume opening
/// - safer close/flush behavior
/// - better protection against partial-file corruption
class PositionalFileWriter {
  static const int defaultBufferSize = 256 * 1024;

  final RandomAccessFile _file;
  final int threadCount;
  final int _bufferSize;

  final List<BytesBuilder> _buffers;
  final List<int> _bufferFilePositions;

  final Lock _flushLock = Lock();
  final List<Lock> _threadLocks;

  final Lock _closeLock = Lock();

  bool _closed = false;

  PositionalFileWriter._(this._file, this.threadCount, this._bufferSize)
    : _buffers = List.generate(threadCount, (_) => BytesBuilder(copy: false)),
      _bufferFilePositions = List.filled(threadCount, 0),
      _threadLocks = List.generate(threadCount, (_) => Lock());

  /// Opens a new file for multi-thread writing.
  ///
  /// If [totalSize] is known, the file is pre-allocated best-effort.
  static Future<PositionalFileWriter> open(
    String path, {
    required int totalSize,
    required int threadCount,
    int bufferSize = defaultBufferSize,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);

    final raf = await file.open(mode: FileMode.write);

    if (totalSize > 0) {
      try {
        await raf.setPosition(totalSize - 1);
        await raf.writeByte(0);
        await raf.setPosition(0);
      } catch (e) {
        debugPrint(
          '[PositionalFileWriter] Pre-allocation failed (non-fatal): $e',
        );
      }
    }

    return PositionalFileWriter._(raf, threadCount, bufferSize);
  }

  /// Opens an existing partial file for resume WITHOUT truncating it.
  ///
  /// - If the file exists, opens it in non-truncating [FileMode.append] so all
  ///   previously downloaded bytes are preserved. Positional writes via
  ///   [setPosition] + [writeFrom] work correctly on all platforms because
  ///   [RandomAccessFile] allows seeking regardless of the open mode.
  /// - If the file does not exist, creates it in [FileMode.write].
  /// - Never calls [FileMode.write] on an existing file (which would truncate).
  static Future<PositionalFileWriter> openForResume(
    String path, {
    required int threadCount,
    int bufferSize = defaultBufferSize,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);

    final exists = await file.exists();
    final RandomAccessFile raf = exists
        ? await file.open(mode: FileMode.append)
        : await file.open(mode: FileMode.write);

    return PositionalFileWriter._(raf, threadCount, bufferSize);
  }

  /// Writes [data] at [filePosition] for [threadIndex].
  Future<void> write(int threadIndex, int filePosition, Uint8List data) async {
    // FIX(R1): Brief closed-state check under _closeLock, then release immediately
    // so per-thread I/O proceeds in parallel under _threadLocks.
    await _closeLock.synchronized(() {
      if (_closed) {
        throw StateError('PositionalFileWriter is closed.');
      }
    });

    if (data.isEmpty) return;

    await _threadLocks[threadIndex].synchronized(() async {
      // Re-check under thread lock in case close() raced.
      if (_closed) {
        throw StateError('PositionalFileWriter is closed.');
      }

      final buffer = _buffers[threadIndex];

      if (buffer.isEmpty) {
        _bufferFilePositions[threadIndex] = filePosition;
      } else {
        final expectedNextPosition =
            _bufferFilePositions[threadIndex] + buffer.length;

        // If the incoming write is not contiguous, flush the current buffer
        // first so we never merge non-adjacent ranges into one write.
        if (filePosition != expectedNextPosition) {
          await _flushLocked(threadIndex);
          _bufferFilePositions[threadIndex] = filePosition;
        }
      }

      buffer.add(data);

      if (buffer.length >= _bufferSize) {
        await _flushLocked(threadIndex);
      }
    });
  }

  /// Flushes buffered bytes for one thread.
  Future<void> flush(int threadIndex) async {
    await _threadLocks[threadIndex].synchronized(() async {
      await _flushLocked(threadIndex);
    });
  }

  /// Flushes all thread buffers.
  Future<void> flushAll() async {
    for (int i = 0; i < threadCount; i++) {
      await flush(i);
    }
  }

  /// Flushes everything and closes the underlying file.
  Future<void> close() async {
    await _closeLock.synchronized(() async {
      if (_closed) return;
      _closed = true;
    });

    // FIX(R1): Flush and close OUTSIDE _closeLock so we don't deadlock with
    // in-flight writes that are waiting on _closeLock.
    await flushAll();

    try {
      await _file.close();
    } catch (_) {
      // Ignore close errors.
    }
  }

  /// Returns the current file length.
  Future<int> fileSize() async {
    return _file.length();
  }

  Future<void> _flushLocked(int threadIndex) async {
    final buffer = _buffers[threadIndex];
    if (buffer.isEmpty) return;

    final bytes = buffer.takeBytes();

    await _flushLock.synchronized(() async {
      await _file.setPosition(_bufferFilePositions[threadIndex]);
      await _file.writeFrom(bytes);
    });

    _bufferFilePositions[threadIndex] += bytes.length;
  }
}
