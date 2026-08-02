import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import '../../../features/downloads/models/download_task.dart';

class ConnectionWarmer {
  static final _log = Logger('ConnectionWarmer');
  static final Map<String, DateTime> _warmedHosts = {};
  static const _warmTtl = Duration(minutes: 5);
  static const _maxWarmedHosts = 10;

  static Future<void> warmConnection(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasAuthority) return;

      final host = uri.host;
      final lastWarm = _warmedHosts[host];
      if (lastWarm != null && DateTime.now().difference(lastWarm) < _warmTtl) {
        return;
      }

      if (_warmedHosts.length >= _maxWarmedHosts) {
        final oldest = _warmedHosts.entries
            .reduce((a, b) => a.value.isBefore(b.value) ? a : b);
        _warmedHosts.remove(oldest.key);
      }

      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
      ));
      await dio.head(
        url,
        options: Options(
          receiveTimeout: const Duration(seconds: 3),
          validateStatus: (_) => true,
        ),
      );
      dio.close();

      _warmedHosts[host] = DateTime.now();
      _log.fine('[ConnectionWarmer] Pre-warmed TLS connection to $host');
    } catch (_) {
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
    } catch (_) {
      return false;
    }
  }

  static void clear() {
    _warmedHosts.clear();
  }
}
