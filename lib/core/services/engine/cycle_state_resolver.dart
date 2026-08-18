import 'package:flutter/foundation.dart';
import '../../domain/cycle_state.dart';
import '../../utils/bounded_lru_cache.dart';

class CycleStateResolver {
  const CycleStateResolver._();

  /// Increased from 256 to 512 to handle torrent-heavy workloads where
  /// libtorrent emits dozens of distinct substate strings per session.
  static final BoundedLruCache<String, CycleState> _resolutionCache =
      BoundedLruCache<String, CycleState>(maxCapacity: 512);

  static const Map<String, CycleState> _libtorrentExact = {
    'checking_files': CycleState.verifying,
    'checking_resume_data': CycleState.verifying,
    'queued_for_checking': CycleState.verifying,
    'checking': CycleState.verifying,
    'verifying': CycleState.verifying,
    'downloading_metadata': CycleState.fetchingMetadata,
    'fetching_metadata': CycleState.fetchingMetadata,
    'metadata': CycleState.fetchingMetadata,
    'allocating': CycleState.allocating,
    'downloading': CycleState.downloading,
    'seeding': CycleState.seeding,
    'finished': CycleState.completed,
    'completed': CycleState.completed,
    'paused': CycleState.paused,
    'stopped': CycleState.paused,
    'stalled': CycleState.stalled,
    'stalled_downloading': CycleState.stalled,
    'stalled_uploading': CycleState.seeding,
    'error': CycleState.failed,
    'failed': CycleState.failed,
    'resuming': CycleState.resuming,
    'retrying': CycleState.retrying,
    'updating_links': CycleState.updatingLinks,
    'updatinglinks': CycleState.updatingLinks,
    'merging': CycleState.merging,
    'muxing': CycleState.merging,
    'starting': CycleState.starting,
    'queued': CycleState.starting,
    'waiting_for_counterpart': CycleState.starting,
    'waiting for counterpart stream…': CycleState.starting,
  };

  static final RegExp _compiledPattern = RegExp(
    r'(?<metadata>downloading_metadata|fetching_metadata|\bmetadata\b)|'
    r'(?<allocating>\ballocat)|'
    r'(?<verifying>checking_files|checking_resume_data|queued_for_checking|\bverif|\bcheck)|'
    r'(?<merging>\bmerg|\bmux)|'
    r'(?<seeding>\bseed)|'
    r'(?<updatingLinks>(?:updating|refresh|refreshing).*?(?:link|url|mirror|expire)|updating_links)|'
    r'(?<retrying>\bretry|\brecover|\brefresh.*connection)|'
    r'(?<resuming>\bresum)|'
    r'(?<starting>\bstart|\bprepar|waiting for counterpart|\bqueued\b|\binit\b)|'
    r'(?<completed>\bcompleted\b|\bdone\b|\bfinished\b)|'
    r'(?<paused>\bpaused\b|\bstopped\b|\bcancel)|'
    r'(?<stalled>\bstall|\bno peers\b|\blooking for peers\b)|'
    r'(?<failed>\berror\b|\bfail\b|\bfailed\b|\btimeout\b|\bexpired\b)',
    caseSensitive: false,
  );

  static CycleState resolve({
    String? statusMessage,
    bool isCancelled = false,
    bool isTorrent = false,
  }) {
    if (isCancelled) return CycleState.paused;
    if (statusMessage == null || statusMessage.trim().isEmpty) {
      return CycleState.downloading;
    }
    final sm = statusMessage.trim();
    if (isTorrent) {
      final normalized = sm.toLowerCase().replaceAll(' ', '_');
      final direct = _libtorrentExact[normalized];
      if (direct != null) return direct;
      final directOriginal = _libtorrentExact[sm.toLowerCase()];
      if (directOriginal != null) return directOriginal;
      return CycleState.fromLibtorrent(sm);
    }
    final cached = _resolutionCache.get(sm);
    if (cached != null) return cached;
    final resolved = _resolveMessage(sm);
    _resolutionCache.put(sm, resolved);
    return resolved;
  }

  static CycleState _resolveMessage(String sm) {
    final match = _compiledPattern.firstMatch(sm);
    if (match == null) {
      return CycleState.downloading;
    }
    if (match.namedGroup('metadata') != null) {
      return CycleState.fetchingMetadata;
    }
    if (match.namedGroup('allocating') != null) return CycleState.allocating;
    if (match.namedGroup('verifying') != null) return CycleState.verifying;
    if (match.namedGroup('merging') != null) return CycleState.merging;
    if (match.namedGroup('seeding') != null) return CycleState.seeding;
    if (match.namedGroup('updatingLinks') != null) {
      return CycleState.updatingLinks;
    }
    if (match.namedGroup('retrying') != null) return CycleState.retrying;
    if (match.namedGroup('resuming') != null) return CycleState.resuming;
    if (match.namedGroup('starting') != null) return CycleState.starting;
    if (match.namedGroup('completed') != null) return CycleState.completed;
    if (match.namedGroup('paused') != null) return CycleState.paused;
    if (match.namedGroup('stalled') != null) return CycleState.stalled;
    if (match.namedGroup('failed') != null) return CycleState.failed;
    return CycleState.downloading;
  }

  @visibleForTesting
  static int get cacheSizeForTesting => _resolutionCache.length;

  @visibleForTesting
  static void clearCacheForTesting() {
    _resolutionCache.clear();
  }
}
