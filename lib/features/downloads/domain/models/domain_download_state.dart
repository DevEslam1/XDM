/// Explicit download lifecycle states within the pure domain core.
enum DomainDownloadState {
  idle,
  queued,
  starting,
  downloading,
  paused,
  merging,
  completing,
  completed,
  failed,
  retrying,
}
