import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';

class DownloadJournal {
  static final _log = Logger('DownloadJournal');
  final String path;
  IOSink? _sink;
  bool _isOpen = false;

  DownloadJournal(this.path);

  Future<void> open() async {
    if (_isOpen) return;
    _sink = File(path).openWrite(mode: FileMode.append);
    _isOpen = true;
  }

  Future<void> writeInit(int threadCount, int totalSize) async {
    _ensureOpen();
    _sink!.writeln(
      jsonEncode({
        't': 'init',
        'threads': threadCount,
        'total': totalSize,
        'ts': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    await _sink!.flush();
  }

  Future<void> recordChunkProgress(int index, int bytes) async {
    _ensureOpen();
    // Do NOT flush here. Flushing on every chunk causes severe disk thrashing
    // and UI freezes on large files. Durability is provided by the periodic
    // writeCheckpoint() below and the final flush in close().
    _sink!.writeln(
      jsonEncode({
        't': 'chunk',
        'i': index,
        'b': bytes,
        'ts': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  Future<void> writeCheckpoint(List<int> chunkProgress, int totalSize) async {
    _ensureOpen();
    _sink!.writeln(
      jsonEncode({
        't': 'checkpoint',
        'chunks': chunkProgress,
        'total': totalSize,
        'ts': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    await _sink!.flush();
  }

  static Future<List<int>?> recover(String journalPath) async {
    final file = File(journalPath);
    if (!await file.exists()) return null;

    List<int>? lastCheckpoint;
    int? threadCount;

    try {
      // Stream the journal line-by-line instead of readAsLines(), which loads
      // the entire (potentially huge) journal into memory and can OOM on
      // long-running downloads.
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
        } catch (_) {}
      }
    } catch (e) {
      _log.warning('Journal recovery failed for $journalPath: $e');
      return null;
    }

    if (lastCheckpoint != null && lastCheckpoint.isEmpty) {
      _log.warning(
        'Journal recovery for $journalPath yielded empty checkpoint '
        '(threadCount was null in init event). Treating as no journal.',
      );
      return null;
    }
    return lastCheckpoint;
  }

  Future<void> close() async {
    if (!_isOpen) return;
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _isOpen = false;
  }

  Future<void> delete() async {
    await close();
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      _log.warning('Failed to delete journal $path: $e');
    }
  }

  void _ensureOpen() {
    if (!_isOpen || _sink == null) {
      throw StateError('Journal not opened. Call open() first.');
    }
  }
}
