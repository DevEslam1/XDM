/// Explicit reasons for pausing a download task.
enum PauseReason {
  user,
  background,
  batterySaver,
  diskFull,
  networkLost,
  scheduled,
  appRestarted,
  urlExpired;

  static const PauseReason userRequested = PauseReason.user;
  static const PauseReason batteryLow = PauseReason.batterySaver;

  static PauseReason? fromName(String? name, {PauseReason? fallback}) {
    if (name == null || name.trim().isEmpty) return fallback;
    final normalized = name.trim();
    for (final v in PauseReason.values) {
      if (v.name == normalized) return v;
    }
    return switch (normalized.toLowerCase()) {
      'user' || 'userrequested' || 'user_requested' => PauseReason.user,
      'batterysaver' ||
      'battery_saver' ||
      'batterylow' ||
      'battery_low' =>
        PauseReason.batterySaver,
      'diskfull' || 'disk_full' => PauseReason.diskFull,
      'networklost' || 'network_lost' => PauseReason.networkLost,
      'scheduled' => PauseReason.scheduled,
      'apprestarted' || 'app_restarted' => PauseReason.appRestarted,
      'urlexpired' || 'url_expired' => PauseReason.urlExpired,
      _ => fallback,
    };
  }
}
