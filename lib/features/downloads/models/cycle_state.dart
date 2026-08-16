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
  static CycleState fromLibtorrent(String? stateLabel) {
    if (stateLabel == null || stateLabel.trim().isEmpty) {
      return CycleState.downloading;
    }
    final s = stateLabel.trim().toLowerCase().replaceAll(' ', '_');

    // 1. Fast exact match lookup
    final direct = _libtorrentStateMap[s];
    if (direct != null) return direct;

    // 2. Substring fallback matching for compound or unformatted states
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
    if (s.contains('allocating')) return CycleState.allocating;
    if (s.contains('finished') || s.contains('completed')) return CycleState.completed;
    if (s.contains('seeding')) return CycleState.seeding;
    if (s.contains('paused') || s.contains('stopped')) return CycleState.paused;
    if (s.contains('stalled')) return CycleState.stalled;
    if (s.contains('error') || s.contains('failed')) return CycleState.failed;
    if (s.contains('resuming')) return CycleState.resuming;
    if (s.contains('retrying')) return CycleState.retrying;
    if (s.contains('updating_links')) return CycleState.updatingLinks;
    if (s.contains('merging') || s.contains('muxing')) return CycleState.merging;
    if (s.contains('starting') || s.contains('queued')) return CycleState.starting;
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
