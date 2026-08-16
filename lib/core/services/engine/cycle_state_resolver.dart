import '../../../features/downloads/models/cycle_state.dart';

/// Unified resolver for deriving canonical [CycleState] across all engine phases,
/// workers, and download types.
class CycleStateResolver {
  const CycleStateResolver._();

  static final _metadataRegex =
      RegExp(r'\b(fetching[_\s]metadata|metadata)\b', caseSensitive: false);
  static final _allocatingRegex =
      RegExp(r'\b(allocat\w*)\b', caseSensitive: false);
  static final _verifyingRegex = RegExp(
      r'\b(verif\w*|check\w*|checking[_\s]resume[_\s]data|checking[_\s]files)\b',
      caseSensitive: false);
  static final _mergingRegex =
      RegExp(r'\b(merg\w*|mux\w*)\b', caseSensitive: false);
  static final _seedingRegex = RegExp(r'\b(seed\w*)\b', caseSensitive: false);
  static final _completedRegex =
      RegExp(r'\b(completed|done|finished)\b', caseSensitive: false);
  static final _pausedRegex =
      RegExp(r'\b(paused|stopped)\b', caseSensitive: false);
  static final _stalledRegex = RegExp(r'\b(stall\w*)\b', caseSensitive: false);
  static final _failedRegex =
      RegExp(r'\b(error|fail\w*)\b', caseSensitive: false);
  static final _updatingLinksRegex = RegExp(
    r'\b(?:updating\s+(?:links?|urls?|mirrors?)|refresh(?:ing)?\s+(?:links?|urls?|mirrors?))\b',
    caseSensitive: false,
  );
  static final _retryingRegex = RegExp(r'\bretry\w*\b', caseSensitive: false);
  static final _resumingRegex = RegExp(r'\bresum\w*\b', caseSensitive: false);
  static final _startingRegex = RegExp(
      r'\b(start\w*|prepar\w*|waiting for counterpart\w*)\b',
      caseSensitive: false);

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

    if (_metadataRegex.hasMatch(sm)) {
      return CycleState.fetchingMetadata;
    }
    if (_allocatingRegex.hasMatch(sm)) {
      return CycleState.allocating;
    }
    if (_verifyingRegex.hasMatch(sm)) {
      return CycleState.verifying;
    }
    if (_mergingRegex.hasMatch(sm)) {
      return CycleState.merging;
    }
    if (_seedingRegex.hasMatch(sm)) {
      return CycleState.seeding;
    }
    if (_updatingLinksRegex.hasMatch(sm)) {
      return CycleState.updatingLinks;
    }
    if (_retryingRegex.hasMatch(sm)) {
      return CycleState.retrying;
    }
    if (_resumingRegex.hasMatch(sm)) {
      return CycleState.resuming;
    }
    if (_startingRegex.hasMatch(sm)) {
      return CycleState.starting;
    }
    if (_completedRegex.hasMatch(sm)) {
      return CycleState.completed;
    }
    if (_pausedRegex.hasMatch(sm)) {
      return CycleState.paused;
    }
    if (_stalledRegex.hasMatch(sm)) {
      return CycleState.stalled;
    }
    if (_failedRegex.hasMatch(sm)) {
      return CycleState.failed;
    }
    return CycleState.downloading;
  }
}
