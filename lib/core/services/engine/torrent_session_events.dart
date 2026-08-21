import 'dart:typed_data';

/// Domain events emitted by the alert-driven BitTorrent engine.
sealed class TorrentSessionEvent {
  final int torrentId;
  final DateTime timestamp;

  const TorrentSessionEvent({
    required this.torrentId,
    required this.timestamp,
  });
}

/// Emitted when torrent metadata is downloaded or loaded.
class MetadataReceivedEvent extends TorrentSessionEvent {
  final String name;
  final int totalWanted;
  final List<Map<String, dynamic>> files;

  MetadataReceivedEvent({
    required super.torrentId,
    required super.timestamp,
    required this.name,
    required this.totalWanted,
    required this.files,
  });
}

/// Emitted when torrent is paused gracefully in native session.
class TorrentPausedAlertEvent extends TorrentSessionEvent {
  final String message;

  TorrentPausedAlertEvent({
    required super.torrentId,
    required super.timestamp,
    this.message = '',
  });
}

/// Emitted when torrent resumes downloading/seeding.
class TorrentResumedAlertEvent extends TorrentSessionEvent {
  TorrentResumedAlertEvent({
    required super.torrentId,
    required super.timestamp,
  });
}

/// Emitted when a piece has been verified and saved to disk.
class PieceFinishedEvent extends TorrentSessionEvent {
  final int pieceIndex;
  final int totalWantedDone;
  final int piecesHave;
  final int piecesTotal;
  final List<bool> pieceBitfield;

  PieceFinishedEvent({
    required super.torrentId,
    required super.timestamp,
    required this.pieceIndex,
    required this.totalWantedDone,
    required this.piecesHave,
    required this.piecesTotal,
    required this.pieceBitfield,
  });
}

/// Emitted when fastresume blob is generated and ready to be durably persisted.
class SaveResumeDataCompletedEvent extends TorrentSessionEvent {
  final Uint8List resumeData;

  SaveResumeDataCompletedEvent({
    required super.torrentId,
    required super.timestamp,
    required this.resumeData,
  });
}

/// Emitted when tracker responds successfully.
class TrackerReplyEvent extends TorrentSessionEvent {
  final String trackerUrl;
  final int numPeers;

  TrackerReplyEvent({
    required super.torrentId,
    required super.timestamp,
    required this.trackerUrl,
    required this.numPeers,
  });
}

/// Emitted when tracker communication fails.
class TrackerErrorEvent extends TorrentSessionEvent {
  final String trackerUrl;
  final String error;

  TrackerErrorEvent({
    required super.torrentId,
    required super.timestamp,
    required this.trackerUrl,
    required this.error,
  });
}

/// Emitted when native session rejects fastresume data.
class FastresumeRejectedEvent extends TorrentSessionEvent {
  final String reason;

  FastresumeRejectedEvent({
    required super.torrentId,
    required super.timestamp,
    required this.reason,
  });
}

/// Emitted on unrecoverable native torrent error.
class TorrentErrorAlertEvent extends TorrentSessionEvent {
  final String error;

  TorrentErrorAlertEvent({
    required super.torrentId,
    required super.timestamp,
    required this.error,
  });
}

/// Emitted when stopped-announce completes before pause.
class StoppedAnnounceEvent extends TorrentSessionEvent {
  StoppedAnnounceEvent({
    required super.torrentId,
    required super.timestamp,
  });
}

/// Emitted on coarse UI telemetry poll ticks.
class StatusTickEvent extends TorrentSessionEvent {
  final double progress;
  final int downloadRate;
  final int uploadRate;
  final int totalDone;
  final int totalWanted;
  final int totalWantedDone;
  final int numPeers;
  final int numSeeds;
  final String stateLabel;
  final List<int> fileProgress;
  final List<int> filePriorities;
  final List<bool> piecesBitfield;
  final int piecesHave;
  final int piecesTotal;

  StatusTickEvent({
    required super.torrentId,
    required super.timestamp,
    required this.progress,
    required this.downloadRate,
    required this.uploadRate,
    required this.totalDone,
    required this.totalWanted,
    required this.totalWantedDone,
    required this.numPeers,
    required this.numSeeds,
    required this.stateLabel,
    this.fileProgress = const [],
    this.filePriorities = const [],
    this.piecesBitfield = const [],
    this.piecesHave = 0,
    this.piecesTotal = 0,
  });
}

/// Emitted when user updates selective file priorities.
class FilePrioritiesChangedEvent extends TorrentSessionEvent {
  final List<int> priorities;
  final int newTotalWanted;
  final int newTotalWantedDone;

  FilePrioritiesChangedEvent({
    required super.torrentId,
    required super.timestamp,
    required this.priorities,
    required this.newTotalWanted,
    required this.newTotalWantedDone,
  });
}
