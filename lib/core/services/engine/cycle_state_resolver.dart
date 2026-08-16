import '../../../features/downloads/models/cycle_state.dart';

/// Unified high-performance resolver for deriving canonical [CycleState] across all engine phases,
/// workers, and download types without expensive RegExp allocations.
class CycleStateResolver {
  const CycleStateResolver._();

  /// Resolves the canonical [CycleState] given [statusMessage], cancellation flag,
  /// and whether the download is a BitTorrent transfer.
  static CycleState resolve({
    String? statusMessage,
    bool isCancelled = false,
    bool isTorrent = false,
  }) {
    if (isCancelled) return CycleState.paused;
    if (isTorrent) return CycleState.fromLibtorrent(statusMessage);

    final sm = statusMessage?.trim() ?? '';
    if (sm.isEmpty) return CycleState.downloading;

    final s = sm.toLowerCase();

    // Fast static keyword checks in exact precedence order
    if (s.contains('metadata')) {
      return CycleState.fetchingMetadata;
    }
    if (s.contains('allocat')) {
      return CycleState.allocating;
    }
    if (s.contains('verif') || s.contains('check')) {
      return CycleState.verifying;
    }
    if (s.contains('merg') || s.contains('mux')) {
      return CycleState.merging;
    }
    if (s.contains('seed')) {
      return CycleState.seeding;
    }
    if ((s.contains('updating') || s.contains('refresh')) &&
        (s.contains('link') || s.contains('url') || s.contains('mirror'))) {
      return CycleState.updatingLinks;
    }
    if (s.contains('retry')) {
      return CycleState.retrying;
    }
    if (s.contains('resum')) {
      return CycleState.resuming;
    }
    if (s.contains('start') ||
        s.contains('prepar') ||
        s.contains('waiting for counterpart')) {
      return CycleState.starting;
    }
    if (s.contains('completed') ||
        s.contains('done') ||
        s.contains('finished')) {
      return CycleState.completed;
    }
    if (s.contains('paused') || s.contains('stopped')) {
      return CycleState.paused;
    }
    if (s.contains('stall')) {
      return CycleState.stalled;
    }
    if (s.contains('error') || s.contains('fail')) {
      return CycleState.failed;
    }

    return CycleState.downloading;
  }
}
