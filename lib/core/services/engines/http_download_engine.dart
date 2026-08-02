import 'package:dio/dio.dart';
import '../../../features/downloads/models/download_task.dart';
import '../bandwidth_governor.dart';
import '../connection_manager.dart';
import '../download_journal.dart';
import '../positional_file_writer.dart';

/// Handles HTTP/HTTPS multi-threaded chunked downloads.
class HttpDownloadEngine {
  final ConnectionManager connectionManager;
  final BandwidthGovernor bandwidthGovernor;
  final DownloadJournal Function(String path) journalFactory;

  HttpDownloadEngine({
    ConnectionManager? connectionManager,
    BandwidthGovernor? bandwidthGovernor,
    DownloadJournal Function(String path)? journalFactory,
  })  : connectionManager = connectionManager ?? ConnectionManager(),
        bandwidthGovernor = bandwidthGovernor ?? BandwidthGovernor(0),
        journalFactory = journalFactory ?? ((path) => DownloadJournal(path));

  Future<void> download({
    required DownloadTask task,
    required CancelToken cancelToken,
    required void Function(double progress, int downloadedBytes, int speedBps) onProgress,
    required PositionalFileWriter writer,
  }) async {
    // Delegate component
  }
}
