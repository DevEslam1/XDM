import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';
import 'download_engine.dart';
import 'service_registry.dart';

final _log = Logger('PositionalFileWriter');

/// I/O failure inside the writer. The engine maps message heuristics
/// (ENOSPC / "space") onto [InsufficientStorageException].
class PositionalFileWriterException implements Exception {
  const PositionalFileWriterException(this.message);
  final String message;
  @override
  String toString() => 'PositionalFileWriterException: $message';
}

/// Buffer for accumulating writes per chunk before performing disk I/O.
class _ChunkBuffer {
  _ChunkBuffer(this.maxCapacity);

  final int maxCapacity;
  int startPos = -1;
  final BytesBuilder builder = BytesBuilder(copy: false);

  int get length => builder.length;
  bool get isEmpty => builder.isEmpty;
  bool get isNotEmpty => builder.isNotEmpty;

  void add(int absolutePosition, Uint8List data) {
    if (isEmpty) {
      startPos = absolutePosition;
    }
    builder.add(data);
  }

  Uint8List takeBytes() {
    final bytes = builder.takeBytes();
    startPos = -1;
    return bytes;
  }
}

/// Random-access writer for chunked downloads with per-chunk handles and write buffers.
class PositionalFileWriter
    implements DisposableService, MemoryPressureListener {
  PositionalFileWriter._({
    required this.path,
    required this.totalSize,
    required this.threadCount,
    int? bufferSize,
    int? maxPendingBytes,
  })  : _bufferSize = bufferSize ?? 256 * 1024,
        maxPendingBytes = maxPendingBytes ?? defaultMaxPendingBytes,
        _highWater = List<int>.filled(threadCount < 1 ? 1 : threadCount, 0) {
    ServiceRegistry.registerMemoryPressureListener(this);
  }

  static const int defaultMaxPendingBytes = 8 * 1024 * 1024; // 8MB

  final String path;
  final int totalSize;
  final int threadCount;
  final int maxPendingBytes;
  int _bufferSize;
  int _pendingBytes = 0;
  final Lock _metaLock = Lock();
  final List<int> _highWater;

  @visibleForTesting
  int get pendingBytes => _pendingBytes;

  void setBufferSize(int newSize) {
    if (newSize > 0) {
      _bufferSize = newSize;
    }
  }

  final Map<int, RandomAccessFile> _handles = {};
  final Map<int, Lock> _handleLocks = {};
  final Map<int, _ChunkBuffer> _buffers = {};
  Completer<void>? _drainCompleter;
  bool _closed = false;

  static Future<PositionalFileWriter> open(
    String path, {
    required int totalSize,
    required int threadCount,
    int? bufferSize,
    int? maxPendingBytes,
  }) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      final raf = await file.open(mode: FileMode.write);
      if (totalSize > 0) {
        await raf.truncate(totalSize);
      }
      await raf.close();

      final writer = PositionalFileWriter._(
        path: path,
        totalSize: totalSize,
        threadCount: threadCount,
        bufferSize: bufferSize,
        maxPendingBytes: maxPendingBytes,
      );
      return writer;
    } catch (e) {
      throw PositionalFileWriterException('open failed: $e');
    }
  }

  static Future<PositionalFileWriter> openForResume(
    String path, {
    required int threadCount,
    int? totalSize,
    int? bufferSize,
    int? maxPendingBytes,
  }) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        await file.parent.create(recursive: true);
        final raf = await file.open(mode: FileMode.write);
        if (totalSize != null && totalSize > 0) {
          await raf.truncate(totalSize);
        }
        await raf.close();
      } else {
        final raf = await file.open(mode: FileMode.append);
        try {
          if (totalSize != null && totalSize > 0) {
            final len = await raf.length();
            if (len != totalSize) {
              await raf.truncate(totalSize);
            }
          }
        } finally {
          await raf.close();
        }
      }

      return PositionalFileWriter._(
        path: path,
        totalSize: totalSize ?? 0,
        threadCount: threadCount,
        bufferSize: bufferSize,
        maxPendingBytes: maxPendingBytes,
      );
    } on PositionalFileWriterException {
      rethrow;
    } catch (e) {
      throw PositionalFileWriterException('openForResume failed: $e');
    }
  }

  static const int _maxHandles = 8;

  Future<RandomAccessFile> _getHandle(int threadIndex) async {
    if (_closed) throw const PositionalFileWriterException('writer is closed');
    final key = threadIndex < 0 ? 0 : threadIndex;
    final handleKey = key % _maxHandles;

    if (!_handles.containsKey(handleKey) || !_buffers.containsKey(key)) {
      await _metaLock.synchronized(() async {
        _checkOpen();
        _buffers[key] ??= _ChunkBuffer(_bufferSize);
        if (!_handles.containsKey(handleKey)) {
          try {
            final file = File(path);
            final raf = await file.open(mode: FileMode.append);
            _handles[handleKey] = raf;
            _handleLocks[handleKey] = Lock();
          } catch (e) {
            throw PositionalFileWriterException('failed to open thread handle: $e');
          }
        }
      });
    }
    return _handles[handleKey]!;
  }

  /// Writes [data] at [absolutePosition].
  Future<void> write(
      int threadIndex, int absolutePosition, Uint8List data) async {
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

    // Bounded write buffer: drain when pending bytes exceed maxPendingBytes
    while (_pendingBytes + data.length > maxPendingBytes && !_closed) {
      await flushBuffers();
      if (_pendingBytes + data.length > maxPendingBytes && !_closed) {
        _drainCompleter ??= Completer<void>();
        try {
          await _drainCompleter!.future
              .timeout(const Duration(milliseconds: 100));
        } catch (_) {
          // Timeout fallback - loop will re-evaluate conditions
        }
      }
    }

    final key = threadIndex < 0 ? 0 : threadIndex;
    final handleKey = key % _maxHandles;
    final raf = await _getHandle(key);
    final handleLock = _handleLocks[handleKey]!;
    final buffer = _buffers[key]!;

    try {
      await handleLock.synchronized(() async {
        _checkOpen();

        // Check if write is non-sequential with buffer start
        if (buffer.isNotEmpty &&
            buffer.startPos + buffer.length != absolutePosition) {
          await _flushBufferInternal(raf, buffer);
        }

        buffer.add(absolutePosition, data);
        _pendingBytes += data.length;
        _bytesSinceLastFlush += data.length;

        if (buffer.length >= _bufferSize) {
          await _flushBufferInternal(raf, buffer);
        }

        if (threadIndex >= 0 && threadIndex < _highWater.length) {
          final end = absolutePosition + data.length;
          if (end > _highWater[threadIndex]) _highWater[threadIndex] = end;
        }
      });
    } on FileSystemException catch (e) {
      final osError = e.osError;
      if (osError != null &&
          (osError.errorCode == 28 || osError.errorCode == 112)) {
        throw const InsufficientStorageException();
      }
      throw PositionalFileWriterException('write failed: ${e.message}');
    }
  }

  Future<void> _flushBufferInternal(
      RandomAccessFile raf, _ChunkBuffer buffer) async {
    if (buffer.isEmpty) return;
    final pos = buffer.startPos;
    final bytes = buffer.takeBytes();
    _pendingBytes = math.max(0, _pendingBytes - bytes.length);
    if (_pendingBytes < maxPendingBytes &&
        _drainCompleter != null &&
        !_drainCompleter!.isCompleted) {
      _drainCompleter!.complete();
      _drainCompleter = null;
    }
    try {
      await raf.setPosition(pos);
      await raf.writeFrom(bytes);
    } on FileSystemException catch (e) {
      // Detect disk-full specifically
      final osError = e.osError;
      if (osError != null &&
          (osError.errorCode == 28 || osError.errorCode == 112)) {
        throw const InsufficientStorageException();
      }
      if (e.message.toLowerCase().contains('no space left') ||
          e.message.toLowerCase().contains('not enough space')) {
        throw const InsufficientStorageException();
      }
      throw PositionalFileWriterException('write failed: $e');
    } catch (e) {
      throw PositionalFileWriterException('write failed: $e');
    }
  }

  /// Durability barrier for a specific [threadIndex] or all if -1.
  Future<void> flush([int threadIndex = -1]) async {
    _checkOpen();
    if (threadIndex >= 0) {
      final handleKey = threadIndex % _maxHandles;
      final handle = _handles[handleKey];
      final lock = _handleLocks[handleKey];
      final buffer = _buffers[threadIndex];
      if (handle != null && lock != null && buffer != null) {
        await lock.synchronized(() async {
          _checkOpen();
          await _flushBufferInternal(handle, buffer);
          await handle.flush();
        });
      }
    } else {
      await flushAll();
    }
  }

  Future<void> flushAll() async {
    _checkOpen();
    for (final entry in _handles.entries) {
      final handleKey = entry.key;
      final handle = entry.value;
      final lock = _handleLocks[handleKey]!;
      await lock.synchronized(() async {
        if (!_closed) {
          for (final bufferEntry in _buffers.entries) {
            if (bufferEntry.key % _maxHandles == handleKey) {
              await _flushBufferInternal(handle, bufferEntry.value);
            }
          }
          await handle.flush();
        }
      });
    }
  }

  DateTime _lastPacedFlush = DateTime.fromMillisecondsSinceEpoch(0);
  int _bytesSinceLastFlush = 0;
  static const Duration minFlushInterval =
      Duration(milliseconds: 2000); // was 500ms
  static const int flushByteThreshold = 4 * 1024 * 1024; // was 1MB

  /// Paced flush: flushes only if 2000ms has elapsed or 4MB written since last flush (F-01/F-02).
  Future<void> flushPaced() async {
    final now = DateTime.now();
    if (now.difference(_lastPacedFlush) >= minFlushInterval ||
        _bytesSinceLastFlush >= flushByteThreshold) {
      _lastPacedFlush = now;
      _bytesSinceLastFlush = 0;
      await flushBuffers();
    }
  }

  /// Flushes buffered writes to the OS without an fsync barrier. Used for
  /// periodic progress saves where full durability is unnecessary; call
  /// [flushAll] at pause/stop/completion to force durability.
  Future<void> flushBuffers() async {
    _checkOpen();
    for (final entry in _handles.entries) {
      final handleKey = entry.key;
      final handle = entry.value;
      final lock = _handleLocks[handleKey]!;
      await lock.synchronized(() async {
        if (!_closed) {
          for (final bufferEntry in _buffers.entries) {
            if (bufferEntry.key % _maxHandles == handleKey) {
              await _flushBufferInternal(handle, bufferEntry.value);
            }
          }
        }
      });
    }
  }

  /// Reads a byte range back from disk.
  Future<Uint8List> readRange(int start, int length) async {
    return _metaLock.synchronized(() async {
      _checkOpen();
      await flushAll();
      RandomAccessFile? tempRaf;
      try {
        final file = File(path);
        tempRaf = await file.open(mode: FileMode.read);
        await tempRaf.setPosition(start);
        final bytes = await tempRaf.read(length);
        return bytes;
      } catch (e) {
        throw PositionalFileWriterException('readRange failed: $e');
      } finally {
        await tempRaf?.close();
      }
    });
  }

  Future<int> length() async {
    return _metaLock.synchronized(() async {
      _checkOpen();
      await flushAll();
      final file = File(path);
      if (await file.exists()) {
        return file.length();
      }
      return 0;
    });
  }

  Future<int> fileSize() => length();

  @override
  void onMemoryPressure() {
    if (!_closed) {
      unawaited(flushBuffers());
    }
  }

  @override
  Future<void> dispose() => close();

  Future<void> close() async {
    ServiceRegistry.unregisterMemoryPressureListener(this);
    await _metaLock.synchronized(() async {
      if (_closed) return;
      try {
        await flushAll(); // let errors propagate
      } on PositionalFileWriterException {
        rethrow; // disk-full must not be swallowed
      } catch (e, st) {
        _log.warning('flushAll during close failed: $e', e, st);
      } finally {
        _closed = true;
        for (final entry in _handles.entries) {
          final handleKey = entry.key;
          final handle = entry.value;
          final lock = _handleLocks[handleKey];
          try {
            if (lock != null) {
              await lock.synchronized(() async {
                for (final bufferEntry in _buffers.entries) {
                  if (bufferEntry.key % _maxHandles == handleKey) {
                    try {
                      await _flushBufferInternal(handle, bufferEntry.value);
                    } catch (e, st) {
                      _log.finest('Flush buffer during close failed', e, st);
                    }
                  }
                }
                try {
                  await handle.flush();
                } catch (e, st) {
                  _log.finest('Flush handle during close failed', e, st);
                }
                try {
                  await handle.close();
                } catch (e, st) {
                  _log.finest('Close handle in lock failed', e, st);
                }
              });
            } else {
              try {
                await handle.close();
              } catch (e, st) {
                _log.finest('Close handle failed', e, st);
              }
            }
          } catch (e, st) {
            _log.finest('Handle cleanup failed', e, st);
          }
        }
        _handles.clear();
        _handleLocks.clear();
        _buffers.clear();
        _pendingBytes = 0;
        if (_drainCompleter != null && !_drainCompleter!.isCompleted) {
          _drainCompleter!.complete();
          _drainCompleter = null;
        }
      }
    });
  }

  void _checkOpen() {
    if (_closed) {
      throw const PositionalFileWriterException('writer is closed');
    }
  }
}
