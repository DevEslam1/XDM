import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';
import '../../../features/downloads/models/download_task.dart';

class ConnectionWarmer {
  static final _log = Logger('ConnectionWarmer');
  static final Map<String, DateTime> _warmedHosts = {};
  static const _warmTtl = Duration(minutes: 5);
  static const _maxWarmedHosts = 10;
  // FIX: Guard concurrent access to _warmedHosts since warmConnection can
  // be called from multiple download tasks simultaneously.
  static final _lock = Lock();

  static Future<void> warmConnection(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasAuthority) return;

      final host = uri.host;
      // Check-and-update under a lock to prevent concurrent warm calls
      // for the same host from racing.
      final shouldWarm = await _lock.synchronized(() {
        final lastWarm = _warmedHosts[host];
        if (lastWarm != null &&
            DateTime.now().difference(lastWarm) < _warmTtl) {
          return false;
        }
        if (_warmedHosts.length >= _maxWarmedHosts) {
          final oldest = _warmedHosts.entries
              .reduce((a, b) => a.value.isBefore(b.value) ? a : b);
          _warmedHosts.remove(oldest.key);
        }
        return true;
      });
      if (!shouldWarm) return;

      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
      ));
      // FIX: Ensure Dio is always closed, even on exception, to prevent
      // socket and memory leaks during pre-warm probes.
      try {
        await dio.head(
          url,
          options: Options(
            receiveTimeout: const Duration(seconds: 3),
            validateStatus: (_) => true,
          ),
        );
      } finally {
        dio.close();
      }

      _warmedHosts[host] = DateTime.now();
      _log.fine('[ConnectionWarmer] Pre-warmed TLS connection to $host');
    } catch (e) {
      _log.info('[ConnectionWarmer] pre-warm skipped: $e');
      // Best effort pre-warming
    }
  }

  static Future<void> warmQueuedTasks(List<DownloadTask> queuedTasks) async {
    final toWarm = queuedTasks.take(3);
    await Future.wait(
      toWarm.map((t) => warmConnection(t.url)),
      eagerError: false,
    );
  }

  static bool isWarmed(String url) {
    try {
      final host = Uri.parse(url).host;
      final lastWarm = _warmedHosts[host];
      return lastWarm != null && DateTime.now().difference(lastWarm) < _warmTtl;
    } catch (e) {
      _log.info(
          '[ConnectionWarmer] URL parse skipped, returning not warmed: $e');
      return false;
    }
  }

  static void clear() {
    _warmedHosts.clear();
  }
}
