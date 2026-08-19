import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import '../../background_gate.dart';
import '../../logging_service.dart';
import '../../power_monitor.dart';
import '../app_database.dart';

class DatabaseMaintenanceService {
  final AppDatabase _db;
  static final _log = Logger('DatabaseMaintenanceService');

  Timer? _maintenanceTimer;
  int maintenanceRuns = 0;
  StreamSubscription<bool>? _screenStateSub;
  VoidCallback? _throttleFactorListener;

  DatabaseMaintenanceService(this._db);

  void start() {
    _scheduleMaintenanceTimer();
    _throttleFactorListener = () => _scheduleMaintenanceTimer();
    PowerMonitor.throttleFactorNotifier.addListener(_throttleFactorListener!);
    _screenStateSub = PowerMonitor.screenStateStream
        .listen((_) => _scheduleMaintenanceTimer());
  }

  void _scheduleMaintenanceTimer() {
    _maintenanceTimer?.cancel();
    final interval = BackgroundGate.adaptInterval(const Duration(minutes: 30));
    _maintenanceTimer = Timer.periodic(interval, (_) async {
      await _runPeriodicMaintenance();
    });
  }

  Future<void> runPeriodicMaintenanceForTesting() => _runPeriodicMaintenance();

  Future<void> _runPeriodicMaintenance() async {
    final activeRows = await _db
        .customSelect(
            "SELECT COUNT(*) as cnt FROM download_tasks WHERE status = 'downloading'")
        .get();
    final hasActiveDownloads = (activeRows.first.read<int>('cnt')) > 0;

    final swCheckpoint = Stopwatch()..start();
    int logPages = 0;
    try {
      if (hasActiveDownloads) {
        if (maintenanceRuns % 4 == 0) {
          final walRows =
              await _db.customSelect('PRAGMA wal_checkpoint(PASS)').get();
          if (walRows.isNotEmpty) {
            final row = walRows.first.data;
            final log = row['log'] ?? 0;
            if (log is num) {
              logPages = log.toInt();
            }
          }
        } else {
          _log.fine(
              '[DatabaseMaintenanceService] Active downloads in progress; skipping periodic wal_checkpoint');
        }
      } else {
        final walRows =
            await _db.customSelect('PRAGMA wal_checkpoint(RESTART)').get();
        if (walRows.isNotEmpty) {
          final row = walRows.first.data;
          final log = row['log'] ?? 0;
          if (log is num) {
            logPages = log.toInt();
          }
        }
      }
      if (logPages > 2500) {
        _log.warning(
            'WAL log size exceeded warning threshold: $logPages pages');
      }
      if (maintenanceRuns % 12 == 0) {
        await _db.customStatement('PRAGMA optimize');
      }
      swCheckpoint.stop();
      if (swCheckpoint.elapsedMilliseconds > 500) {
        _log.info('wal_checkpoint took ${swCheckpoint.elapsedMilliseconds}ms');
      }
    } catch (e) {
      _log.warning('wal_checkpoint failed', e);
    }

    maintenanceRuns++;
    if (maintenanceRuns % 6 == 0 && !hasActiveDownloads) {
      try {
        if (logPages > 1250) {
          _log.warning('WAL too large ($logPages pages), forcing TRUNCATE');
          await _db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
        }
      } catch (e, st) {
        LoggingService.logger('DatabaseMaintenanceService')
            .warning('Operation failed', e, st);
      }
    }
    if (maintenanceRuns % 12 == 0 && !hasActiveDownloads) {
      try {
        final swVacuum = Stopwatch()..start();
        await _db.customStatement('PRAGMA incremental_vacuum(50)');
        try {
          await _db.customStatement('PRAGMA foreign_key_check');
        } catch (e, st) {
          LoggingService.logger('DatabaseMaintenanceService')
              .warning('PRAGMA foreign_key_check failed', e, st);
        }
        swVacuum.stop();
        if (swVacuum.elapsedMilliseconds > 500) {
          _log.info(
              'incremental_vacuum took ${swVacuum.elapsedMilliseconds}ms');
        }
      } catch (e, st) {
        LoggingService.logger('DatabaseMaintenanceService')
            .warning('Periodic vacuum/fk check failed', e, st);
      }
    }
  }

  void dispose() {
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    if (_throttleFactorListener != null) {
      PowerMonitor.throttleFactorNotifier
          .removeListener(_throttleFactorListener!);
      _throttleFactorListener = null;
    }
    _screenStateSub?.cancel();
    _screenStateSub = null;
  }
}
