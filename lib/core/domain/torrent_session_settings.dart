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
  });

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
    return TorrentSessionSettings(
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
