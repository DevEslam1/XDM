import 'dart:io';
import 'dart:typed_data';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';
import '../../features/settings/provider/settings_provider.dart';


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

  final List<DateTime> _lastFlushTimes;

  PositionalFileWriter._(this._file, this.threadCount, this._bufferSize)
      : _buffers = List.generate(threadCount, (_) => BytesBuilder(copy: false)),
        _bufferFilePositions = List.filled(threadCount, 0),
        _lastFlushTimes = List.generate(threadCount, (_) => DateTime.now()),
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
  /// Uses [FileMode.writeOnlyAppend] so existing content is preserved
  /// (no truncation). Immediately after opening, `setPosition(0)` is called
  /// to override any OS-level `O_APPEND` behavior, ensuring that subsequent
  /// positional writes via [setPosition] + [writeFrom] land at the correct
  /// byte offsets across all platforms.
  ///
  /// **Do NOT change this to [FileMode.writeOnly] or [FileMode.write]** —
  /// both truncate the file and would destroy all downloaded data.
  ///
  /// FIX-M12: If the file does not exist or is empty, falls back to [open]
  /// (i.e. starts fresh) to avoid resuming from an empty file, which would
  /// skip pre-allocation and leave the file in an inconsistent state.
  static Future<PositionalFileWriter> openForResume(
    String path, {
    required int threadCount,
    int bufferSize = defaultBufferSize,
    int totalSize = 0,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);

    // FIX-M12: If the file doesn't exist or is empty, treat as a fresh start
    // rather than resuming, to avoid write corruption on empty partial files.
    final existingLength = await file.exists() ? await file.length() : 0;
    if (existingLength == 0) {
      debugPrint(
        '[PositionalFileWriter] openForResume: file empty or missing, '
        'treating as fresh open for path: $path',
      );
      return open(
        path,
        totalSize: totalSize,
        threadCount: threadCount,
        bufferSize: bufferSize,
      );
    }

    // writeOnlyAppend preserves existing bytes (no truncation).
    // We immediately call setPosition to neutralise O_APPEND so that
    // positional writes work correctly.
    final RandomAccessFile raf =
        await file.open(mode: FileMode.writeOnlyAppend);
    // Force position to 0 so subsequent setPosition calls work correctly.
    // On platforms where O_APPEND is forced, we re-open with read/write.
    try {
      await raf.setPosition(0);
      // Verify the position actually stuck
      final pos = await raf.position();
      if (pos != 0) {
        await raf.close();
        // FIX(A2): FileMode.append preserves data (no truncate).
        // DO NOT use FileMode.write here — it truncates the file.
        final raf2 = await file.open(mode: FileMode.append);
        await raf2.setPosition(0);
        return PositionalFileWriter._(raf2, threadCount, bufferSize);
      }
    } catch (_) {
      await raf.close();
      // FIX(A2): FileMode.append preserves data (no truncate).
      // DO NOT use FileMode.write here — it truncates the file.
      final raf2 = await file.open(mode: FileMode.append);
      await raf2.setPosition(0);
      return PositionalFileWriter._(raf2, threadCount, bufferSize);
    }
    return PositionalFileWriter._(raf, threadCount, bufferSize);
  }

  /// Writes [data] at [filePosition] for [threadIndex].
  Future<void> write(int threadIndex, int filePosition, Uint8List data) async {
    await _closeLock.synchronized(() {
      if (_closed) {
        throw StateError('PositionalFileWriter is closed');
      }
    });

    if (data.isEmpty) return;

    await _threadLocks[threadIndex].synchronized(() async {
      if (_closed) {
        throw StateError('PositionalFileWriter is closed');
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

      bool batchingEnabled = true;
      try {
        batchingEnabled = SettingsProvider.instance.diskWriteBatching;
      } catch (_) {}

      final elapsedMs =
          DateTime.now().difference(_lastFlushTimes[threadIndex]).inMilliseconds;

      if (!batchingEnabled || buffer.length >= _bufferSize || elapsedMs >= 500) {
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
    } catch (e) {
      LoggingService.logger('PositionalFileWriter').info(
        '[PositionalFileWriter] file close errors ignored: $e',
      );
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
    int attempts = 0;

    while (true) {
      attempts++;
      try {
        await _flushLock.synchronized(() async {
          await _file.setPosition(_bufferFilePositions[threadIndex]);
          await _file.writeFrom(bytes);
        });

        _bufferFilePositions[threadIndex] += bytes.length;
        break;
      } catch (e) {
        if (attempts >= 3) {
          // Preserve unwritten bytes in buffer if all retries fail
          buffer.add(bytes);
          rethrow;
        }
        await Future.delayed(Duration(milliseconds: 100 * attempts));
      }
    }
  }

  /// Direct positional read used for verification and repair.
  Future<Uint8List> readRange(int start, int length) async {
    await flushAll();
    return await _flushLock.synchronized(() async {
      await _file.setPosition(start);
      return await _file.read(length);
    });
  }

  /// Direct positional write used for chunk repair.
  Future<void> writeAt(int start, List<int> data) async {
    await flushAll();
    await _flushLock.synchronized(() async {
      await _file.setPosition(start);
      await _file.writeFrom(data);
    });
  }
}
