import 'dart:collection';
import 'package:flutter/foundation.dart';

/// Privacy-safe, opt-in production release telemetry aggregator.
///
/// Invariant: NEVER records URLs, query strings, auth tokens, cookies,
/// file paths, or personal data. Only records aggregated ratios and counters.
class ProductionTelemetryService {
  ProductionTelemetryService._();
  static final ProductionTelemetryService instance =
      ProductionTelemetryService._();

  static bool optInEnabled = false;

  int _sessionCount = 1;
  int _cleanExits = 0;
  int _totalTasksCreated = 0;
  int _failedTasks = 0;
  int _resumeAttempts = 0;
  int _resumeMismatches = 0;
  int _mergeAttempts = 0;
  int _mergeFailures = 0;
  int _journalRecoveries = 0;
  int _wakelockFailures = 0;
  int _dbWriteFailures = 0;
  int _jankFrames = 0;
  int _totalFrames = 0;

  // Track recent events using a bounded sliding window
  final Queue<DateTime> _recentFailureTimestamps = Queue();
  static const int _maxEvents = 100;

  void recordSessionStart() {
    _sessionCount++;
  }

  void recordCleanExit() {
    _cleanExits++;
  }

  void recordTaskCreated() {
    if (!optInEnabled) return;
    _totalTasksCreated++;
  }

  void recordTaskFailure() {
    if (!optInEnabled) return;
    _failedTasks++;
    _recentFailureTimestamps.add(DateTime.now());
    while (_recentFailureTimestamps.length > _maxEvents) {
      _recentFailureTimestamps.removeFirst();
    }
  }

  void recordResumeAttempt({required bool isMismatch}) {
    if (!optInEnabled) return;
    _resumeAttempts++;
    if (isMismatch) _resumeMismatches++;
  }

  void recordMergeAttempt({required bool isSuccess}) {
    if (!optInEnabled) return;
    _mergeAttempts++;
    if (!isSuccess) _mergeFailures++;
  }

  void recordJournalRecovery() {
    if (!optInEnabled) return;
    _journalRecoveries++;
  }

  void recordWakelockFailure() {
    if (!optInEnabled) return;
    _wakelockFailures++;
  }

  void recordDbWriteFailure() {
    if (!optInEnabled) return;
    _dbWriteFailures++;
  }

  void recordFrameMetrics({required int total, required int jank}) {
    if (!optInEnabled) return;
    _totalFrames += total;
    _jankFrames += jank;
  }

  /// Calculates privacy-safe telemetry summary for export.
  Map<String, dynamic> generateReport() {
    final double jankRatio =
        _totalFrames > 0 ? (_jankFrames / _totalFrames) : 0.0;
    final double failedDownloadRate =
        _totalTasksCreated > 0 ? (_failedTasks / _totalTasksCreated) : 0.0;
    final double resumeMismatchRate =
        _resumeAttempts > 0 ? (_resumeMismatches / _resumeAttempts) : 0.0;
    final double mergeFailureRate =
        _mergeAttempts > 0 ? (_mergeFailures / _mergeAttempts) : 0.0;

    return {
      'optIn': optInEnabled,
      'sessions': _sessionCount,
      'cleanExits': _cleanExits,
      'jankRatio': (jankRatio * 1000).round() / 1000,
      'failedDownloadRate': (failedDownloadRate * 1000).round() / 1000,
      'resumeMismatchRate': (resumeMismatchRate * 1000).round() / 1000,
      'mergeFailureRate': (mergeFailureRate * 1000).round() / 1000,
      'journalRecoveryCount': _journalRecoveries,
      'wakelockFailures': _wakelockFailures,
      'dbWriteFailures': _dbWriteFailures,
      'totalTasks': _totalTasksCreated,
    };
  }

  @visibleForTesting
  void resetForTesting() {
    _sessionCount = 1;
    _cleanExits = 0;
    _totalTasksCreated = 0;
    _failedTasks = 0;
    _resumeAttempts = 0;
    _resumeMismatches = 0;
    _mergeAttempts = 0;
    _mergeFailures = 0;
    _journalRecoveries = 0;
    _wakelockFailures = 0;
    _dbWriteFailures = 0;
    _jankFrames = 0;
    _totalFrames = 0;
    _recentFailureTimestamps.clear();
    optInEnabled = false;
  }
}
