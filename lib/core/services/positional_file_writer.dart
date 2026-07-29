import 'dart:io';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

class PositionalFileWriter {
  static final _log = Logger('PositionalFileWriter');
  static const int defaultBufferSize = 256 * 1024;

  final RandomAccessFile _file;
  final int threadCount;
  final int _bufferSize;
  final List<BytesBuilder> _buffers;
  final List<int> _bufferFilePositions;
  final Lock _flushLock = Lock();

  PositionalFileWriter._(this._file, this.threadCount, this._bufferSize)
    : _buffers = List.generate(threadCount, (_) => BytesBuilder(copy: false)),
      _bufferFilePositions = List.filled(threadCount, 0);

  static Future<PositionalFileWriter> open(
    String path, {
    required int totalSize,
    required int threadCount,
    int bufferSize = defaultBufferSize,
  }) async {
    final file = await File(path).open(mode: FileMode.write);

    if (totalSize > 0) {
      try {
        await file.setPosition(totalSize - 1);
        await file.writeByte(0);
        await file.setPosition(0);
      } catch (e) {
        _log.warning('Pre-allocation failed (non-fatal): $e');
      }
    }

    return PositionalFileWriter._(file, threadCount, bufferSize);
  }

  static Future<PositionalFileWriter> openForResume(
    String path, {
    required int threadCount,
    int bufferSize = defaultBufferSize,
  }) async {
    final exists = await File(path).exists();
    final RandomAccessFile openedFile;
    if (exists) {
      openedFile = await File(path).open(mode: FileMode.append);
    } else {
      openedFile = await File(path).open(mode: FileMode.write);
    }
    return PositionalFileWriter._(openedFile, threadCount, bufferSize);
  }

  Future<void> write(int threadIndex, int filePosition, Uint8List data) async {
    if (_buffers[threadIndex].isEmpty) {
      _bufferFilePositions[threadIndex] = filePosition;
    }
    _buffers[threadIndex].add(data);

    if (_buffers[threadIndex].length >= _bufferSize) {
      await flush(threadIndex);
    }
  }

  Future<void> flush(int threadIndex) async {
    final buffer = _buffers[threadIndex];
    if (buffer.isEmpty) return;

    final bytes = buffer.takeBytes();
    await _flushLock.synchronized(() async {
      await _file.setPosition(_bufferFilePositions[threadIndex]);
      await _file.writeFrom(bytes);
    });

    _bufferFilePositions[threadIndex] += bytes.length;
  }

  Future<void> flushAll() async {
    for (int i = 0; i < threadCount; i++) {
      await flush(i);
    }
  }

  Future<void> close() async {
    await flushAll();
    await _file.close();
  }

  Future<int> fileSize() async {
    return _file.length();
  }
}
