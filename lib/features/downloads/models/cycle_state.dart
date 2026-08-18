// FIX 6.1: Legal state transitions map and validation

/// Strict cycle state representations covering all download engine phases.
enum CycleState {
  starting,
  allocating,
  fetchingMetadata,
  downloading,
  verifying,
  merging,
  retrying,
  resuming,
  paused,
  stalled,
  seeding,
  completed,
  failed,
  updatingLinks;

  /// FIX 6.1: Map of legally allowed state transitions.
  static const Map<CycleState, Set<CycleState>> legalTransitions = {
    CycleState.starting: {
      CycleState.downloading,
      CycleState.failed,
      CycleState.paused,
      CycleState.fetchingMetadata,
      CycleState.allocating,
      CycleState.verifying,
      CycleState.stalled,
    },
    CycleState.allocating: {
      CycleState.downloading,
      CycleState.failed,
      CycleState.paused,
      CycleState.starting,
      CycleState.stalled,
    },
    CycleState.fetchingMetadata: {
      CycleState.downloading,
      CycleState.failed,
      CycleState.paused,
      CycleState.verifying,
      CycleState.allocating,
      CycleState.stalled,
      CycleState.retrying,
    },
    CycleState.downloading: {
      CycleState.paused,
      CycleState.merging,
      CycleState.completed,
      CycleState.failed,
      CycleState.stalled,
      CycleState.retrying,
      CycleState.updatingLinks,
      CycleState.seeding,
      CycleState.verifying,
    },
    CycleState.verifying: {
      CycleState.downloading,
      CycleState.failed,
      CycleState.paused,
      CycleState.resuming,
      CycleState.completed,
      CycleState.seeding,
      CycleState.stalled,
    },
    CycleState.merging: {
      CycleState.completed,
      CycleState.failed,
      CycleState.paused,
    },
    CycleState.retrying: {
      CycleState.downloading,
      CycleState.failed,
      CycleState.paused,
      CycleState.starting,
      CycleState.merging,
      CycleState.fetchingMetadata,
    },
    CycleState.resuming: {
      CycleState.downloading,
      CycleState.failed,
      CycleState.paused,
      CycleState.verifying,
      CycleState.merging,
    },
    CycleState.paused: {
      CycleState.resuming,
      CycleState.downloading,
      CycleState.failed,
      CycleState.updatingLinks,
      CycleState.starting,
      CycleState.retrying,
    },
    CycleState.stalled: {
      CycleState.downloading,
      CycleState.failed,
      CycleState.paused,
      CycleState.retrying,
      CycleState.fetchingMetadata,
      CycleState.updatingLinks,
    },
    CycleState.seeding: {
      CycleState.completed,
      CycleState.paused,
      CycleState.failed,
    },
    CycleState.completed: {},
    CycleState.failed: {
      CycleState.retrying,
      CycleState.resuming,
      CycleState.starting,
      CycleState.updatingLinks,
    },
    CycleState.updatingLinks: {
      CycleState.downloading,
      CycleState.paused,
      CycleState.failed,
      CycleState.resuming,
      CycleState.starting,
      CycleState.retrying,
    },
  };

  /// FIX 6.1: Validates if transition from [from] to [to] is legally allowed.
  static bool isValidTransition(CycleState? from, CycleState to) {
    if (from == null || from == to) return true;
    final allowed = legalTransitions[from];
    return allowed?.contains(to) ?? false;
  }

  static const Map<String, CycleState> _libtorrentStateMap = {
    'downloading_metadata': CycleState.fetchingMetadata,
    'fetching_metadata': CycleState.fetchingMetadata,
    'metadata': CycleState.fetchingMetadata,
    'allocating': CycleState.allocating,
    'checking_files': CycleState.verifying,
    'queued_for_checking': CycleState.verifying,
    'checking_resume_data': CycleState.verifying,
    'checking': CycleState.verifying,
    'verifying': CycleState.verifying,
    'downloading': CycleState.downloading,
    'seeding': CycleState.seeding,
    'finished': CycleState.completed,
    'completed': CycleState.completed,
    'paused': CycleState.paused,
    'stopped': CycleState.paused,
    'stalled': CycleState.stalled,
    'error': CycleState.failed,
    'failed': CycleState.failed,
    'resuming': CycleState.resuming,
    'retrying': CycleState.retrying,
    'updating_links': CycleState.updatingLinks,
    'merging': CycleState.merging,
    'muxing': CycleState.merging,
    'starting': CycleState.starting,
    'queued': CycleState.starting,
  };

  /// Maps libtorrent state labels / strings to a canonical [CycleState].
  static CycleState fromLibtorrent(String? stateLabel,
      {bool seedingEnabled = true}) {
    if (stateLabel == null || stateLabel.trim().isEmpty) {
      return CycleState.downloading;
    }
    final s = stateLabel.trim().toLowerCase().replaceAll(' ', '_');

    // 1. Fast exact match lookup
    final direct = _libtorrentStateMap[s];
    if (direct != null) {
      if (direct == CycleState.seeding && !seedingEnabled) {
        return CycleState.completed;
      }
      return direct;
    }

    // 2. Substring fallback matching for compound or unformatted states
    if (s.contains('seeding')) {
      return seedingEnabled ? CycleState.seeding : CycleState.completed;
    }
    if (s.contains('queued_for_checking') ||
        s.contains('checking_files') ||
        s.contains('checking_resume_data') ||
        s.contains('verifying') ||
        s.contains('checking')) {
      return CycleState.verifying;
    }
    if (s.contains('downloading_metadata') ||
        s.contains('fetching_metadata') ||
        s.contains('metadata')) {
      return CycleState.fetchingMetadata;
    }
    if (s.contains('allocating')) {
      return CycleState.allocating;
    }
    if (s.contains('finished') || s.contains('completed')) {
      return CycleState.completed;
    }
    if (s.contains('seeding')) {
      return CycleState.seeding;
    }
    if (s.contains('paused') || s.contains('stopped')) {
      return CycleState.paused;
    }
    if (s.contains('stalled')) {
      return CycleState.stalled;
    }
    if (s.contains('error') || s.contains('failed')) {
      return CycleState.failed;
    }
    if (s.contains('resuming')) {
      return CycleState.resuming;
    }
    if (s.contains('retrying')) {
      return CycleState.retrying;
    }
    if (s.contains('updating_links')) {
      return CycleState.updatingLinks;
    }
    if (s.contains('merging') || s.contains('muxing')) {
      return CycleState.merging;
    }
    if (s.contains('starting') || s.contains('queued')) {
      return CycleState.starting;
    }
    return CycleState.downloading; // default
  }

  /// Parses [CycleState] by name (camelCase or snake_case), falling back to [fallback].
  static CycleState? fromName(String? name, {CycleState? fallback}) {
    if (name == null || name.trim().isEmpty) return fallback;
    final normalized = name.trim();
    for (final v in CycleState.values) {
      if (v.name == normalized) return v;
    }
    // Handle snake_case conversions
    return switch (normalized.toLowerCase()) {
      'fetching_metadata' || 'fetchingmetadata' => CycleState.fetchingMetadata,
      'updating_links' || 'updatinglinks' => CycleState.updatingLinks,
      'checking' => CycleState.verifying,
      _ => fallback,
    };
  }
}
