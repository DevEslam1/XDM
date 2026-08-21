import 'package:flutter/foundation.dart';

/// Pure domain value object representing libtorrent session configuration parameters.
/// Decouples core engine and interface contracts from UI-layer settings providers.
@immutable
class TorrentSessionSettings {
  final bool enableDht;
  final bool enableUpnp;
  final bool forceEncrypt;
  final int torrentConnectionsLimit;
  final int downloadRateLimitKbps;
  final int uploadRateLimitKbps;
  final bool sequentialDownload;
  final double shareRatioLimit;
  final int maxSeedingTimeMinutes;

  const TorrentSessionSettings({
    this.enableDht = true,
    this.enableUpnp = true,
    this.forceEncrypt = false,
    this.torrentConnectionsLimit = 200,
    this.downloadRateLimitKbps = 0,
    this.uploadRateLimitKbps = 0,
    this.sequentialDownload = false,
    this.shareRatioLimit = 0.0,
    this.maxSeedingTimeMinutes = 0,
  })  : assert(torrentConnectionsLimit > 0,
            'Connections limit must be greater than zero'),
        assert(downloadRateLimitKbps >= 0,
            'Download rate limit cannot be negative'),
        assert(
            uploadRateLimitKbps >= 0, 'Upload rate limit cannot be negative'),
        assert(
            shareRatioLimit >= 0.0, 'Share ratio limit cannot be negative'),
        assert(maxSeedingTimeMinutes >= 0,
            'Max seeding time cannot be negative');

  // FIX(M4): validated factory that throws ArgumentError on negative limits or connectionsLimit <= 0
  factory TorrentSessionSettings.validated({
    bool enableDht = true,
    bool enableUpnp = true,
    bool forceEncrypt = false,
    int torrentConnectionsLimit = 200,
    int downloadRateLimitKbps = 0,
    int uploadRateLimitKbps = 0,
    bool sequentialDownload = false,
    double shareRatioLimit = 0.0,
    int maxSeedingTimeMinutes = 0,
  }) {
    if (torrentConnectionsLimit <= 0) {
      throw ArgumentError.value(
        torrentConnectionsLimit,
        'torrentConnectionsLimit',
        'Connections limit must be greater than zero',
      );
    }
    if (downloadRateLimitKbps < 0) {
      throw ArgumentError.value(
        downloadRateLimitKbps,
        'downloadRateLimitKbps',
        'Download rate limit cannot be negative',
      );
    }
    if (uploadRateLimitKbps < 0) {
      throw ArgumentError.value(
        uploadRateLimitKbps,
        'uploadRateLimitKbps',
        'Upload rate limit cannot be negative',
      );
    }
    if (shareRatioLimit < 0.0) {
      throw ArgumentError.value(
        shareRatioLimit,
        'shareRatioLimit',
        'Share ratio limit cannot be negative',
      );
    }
    if (maxSeedingTimeMinutes < 0) {
      throw ArgumentError.value(
        maxSeedingTimeMinutes,
        'maxSeedingTimeMinutes',
        'Max seeding time cannot be negative',
      );
    }
    return TorrentSessionSettings(
      enableDht: enableDht,
      enableUpnp: enableUpnp,
      forceEncrypt: forceEncrypt,
      torrentConnectionsLimit: torrentConnectionsLimit,
      downloadRateLimitKbps: downloadRateLimitKbps,
      uploadRateLimitKbps: uploadRateLimitKbps,
      sequentialDownload: sequentialDownload,
      shareRatioLimit: shareRatioLimit,
      maxSeedingTimeMinutes: maxSeedingTimeMinutes,
    );
  }

  TorrentSessionSettings copyWith({
    bool? enableDht,
    bool? enableUpnp,
    bool? forceEncrypt,
    int? torrentConnectionsLimit,
    int? downloadRateLimitKbps,
    int? uploadRateLimitKbps,
    bool? sequentialDownload,
    double? shareRatioLimit,
    int? maxSeedingTimeMinutes,
  }) {
    return TorrentSessionSettings.validated(
      enableDht: enableDht ?? this.enableDht,
      enableUpnp: enableUpnp ?? this.enableUpnp,
      forceEncrypt: forceEncrypt ?? this.forceEncrypt,
      torrentConnectionsLimit:
          torrentConnectionsLimit ?? this.torrentConnectionsLimit,
      downloadRateLimitKbps:
          downloadRateLimitKbps ?? this.downloadRateLimitKbps,
      uploadRateLimitKbps: uploadRateLimitKbps ?? this.uploadRateLimitKbps,
      sequentialDownload: sequentialDownload ?? this.sequentialDownload,
      shareRatioLimit: shareRatioLimit ?? this.shareRatioLimit,
      maxSeedingTimeMinutes:
          maxSeedingTimeMinutes ?? this.maxSeedingTimeMinutes,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TorrentSessionSettings &&
          runtimeType == other.runtimeType &&
          enableDht == other.enableDht &&
          enableUpnp == other.enableUpnp &&
          forceEncrypt == other.forceEncrypt &&
          torrentConnectionsLimit == other.torrentConnectionsLimit &&
          downloadRateLimitKbps == other.downloadRateLimitKbps &&
          uploadRateLimitKbps == other.uploadRateLimitKbps &&
          sequentialDownload == other.sequentialDownload &&
          shareRatioLimit == other.shareRatioLimit &&
          maxSeedingTimeMinutes == other.maxSeedingTimeMinutes;

  @override
  int get hashCode => Object.hash(
        enableDht,
        enableUpnp,
        forceEncrypt,
        torrentConnectionsLimit,
        downloadRateLimitKbps,
        uploadRateLimitKbps,
        sequentialDownload,
        shareRatioLimit,
        maxSeedingTimeMinutes,
      );
}
