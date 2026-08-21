import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import '../../background_gate.dart';
import '../../logging_service.dart';
import '../../power_monitor.dart';
import '../../tick_manager.dart';
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
    _maintenanceTimer = null;
    final interval = BackgroundGate.adaptInterval(const Duration(minutes: 30));
    TickManager.instance.registerTick(
      id: 'database_periodic_maintenance',
      interval: interval,
      priority: TickPriority.normal,
      callback: (_) async {
        await _runPeriodicMaintenance();
      },
    );
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
    int checkpointedPages = 0;
    try {
      if (hasActiveDownloads && maintenanceRuns % 4 != 0) {
        _log.fine(
            '[DatabaseMaintenanceService] Active downloads in progress; skipping periodic wal_checkpoint');
      } else {
        final walRows = await _db
            .customSelect('PRAGMA wal_checkpoint(PASSIVE)')
            .get()
            .timeout(const Duration(seconds: 1));
        if (walRows.isNotEmpty) {
          final row = walRows.first.data;
          final log = row['log'] ?? 0;
          final checkpointed = row['checkpointed'] ?? 0;
          if (log is num) logPages = log.toInt();
          if (checkpointed is num) checkpointedPages = checkpointed.toInt();
          if (checkpointedPages > 100) {
            _log.info(
              '[DatabaseMaintenanceService] wal_checkpoint(PASSIVE) reclaimed $checkpointedPages pages ($logPages log pages)',
            );
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
        // FIX-20: Periodic full VACUUM and ANALYZE every ~2.5 days (720 runs)
        if (maintenanceRuns % 720 == 0) {
          try {
            await _db.customStatement('VACUUM');
            await _db.customStatement('ANALYZE');
          } catch (e, st) {
            LoggingService.logger('DatabaseMaintenanceService')
                .warning('Full VACUUM/ANALYZE failed', e, st);
          }
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
    TickManager.instance.unregisterTick('database_periodic_maintenance');
    if (_throttleFactorListener != null) {
      PowerMonitor.throttleFactorNotifier
          .removeListener(_throttleFactorListener!);
      _throttleFactorListener = null;
    }
    _screenStateSub?.cancel();
    _screenStateSub = null;
  }
}
