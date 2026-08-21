import 'package:flutter/foundation.dart';
import 'torrent_session_events.dart';

/// Immutable domain state for an active torrent in the engine.
@immutable
class TorrentSessionState {
  final int torrentId;
  final String name;
  final String stateLabel;
  final double progress;
  final int downloadRate;
  final int uploadRate;
  final int totalDone;
  final int totalWanted;
  final int totalWantedDone;
  final int numPeers;
  final int numSeeds;
  final int piecesHave;
  final int piecesTotal;
  final List<bool> pieceBitfield;
  final bool hasMetadata;
  final bool isPaused;
  final bool isFinished;
  final bool isSeeding;
  final List<Map<String, dynamic>> files;
  final List<int> fileProgress;
  final List<int> filePriorities;
  final String? errorMessage;
  final bool stoppedAnnounceReceived;

  const TorrentSessionState({
    required this.torrentId,
    this.name = '',
    this.stateLabel = 'Downloading',
    this.progress = 0.0,
    this.downloadRate = 0,
    this.uploadRate = 0,
    this.totalDone = 0,
    this.totalWanted = 0,
    this.totalWantedDone = 0,
    this.numPeers = 0,
    this.numSeeds = 0,
    this.piecesHave = 0,
    this.piecesTotal = 0,
    this.pieceBitfield = const [],
    this.hasMetadata = false,
    this.isPaused = false,
    this.isFinished = false,
    this.isSeeding = false,
    this.files = const [],
    this.fileProgress = const [],
    this.filePriorities = const [],
    this.errorMessage,
    this.stoppedAnnounceReceived = false,
  });

  TorrentSessionState copyWith({
    String? name,
    String? stateLabel,
    double? progress,
    int? downloadRate,
    int? uploadRate,
    int? totalDone,
    int? totalWanted,
    int? totalWantedDone,
    int? numPeers,
    int? numSeeds,
    int? piecesHave,
    int? piecesTotal,
    List<bool>? pieceBitfield,
    bool? hasMetadata,
    bool? isPaused,
    bool? isFinished,
    bool? isSeeding,
    List<Map<String, dynamic>>? files,
    List<int>? fileProgress,
    List<int>? filePriorities,
    String? errorMessage,
    bool? stoppedAnnounceReceived,
  }) {
    return TorrentSessionState(
      torrentId: torrentId,
      name: name ?? this.name,
      stateLabel: stateLabel ?? this.stateLabel,
      progress: progress ?? this.progress,
      downloadRate: downloadRate ?? this.downloadRate,
      uploadRate: uploadRate ?? this.uploadRate,
      totalDone: totalDone ?? this.totalDone,
      totalWanted: totalWanted ?? this.totalWanted,
      totalWantedDone: totalWantedDone ?? this.totalWantedDone,
      numPeers: numPeers ?? this.numPeers,
      numSeeds: numSeeds ?? this.numSeeds,
      piecesHave: piecesHave ?? this.piecesHave,
      piecesTotal: piecesTotal ?? this.piecesTotal,
      pieceBitfield: pieceBitfield ?? this.pieceBitfield,
      hasMetadata: hasMetadata ?? this.hasMetadata,
      isPaused: isPaused ?? this.isPaused,
      isFinished: isFinished ?? this.isFinished,
      isSeeding: isSeeding ?? this.isSeeding,
      files: files ?? this.files,
      fileProgress: fileProgress ?? this.fileProgress,
      filePriorities: filePriorities ?? this.filePriorities,
      errorMessage: errorMessage ?? this.errorMessage,
      stoppedAnnounceReceived:
          stoppedAnnounceReceived ?? this.stoppedAnnounceReceived,
    );
  }

  /// Pure event reducer producing the next immutable [TorrentSessionState].
  static TorrentSessionState reduce(
    TorrentSessionState state,
    TorrentSessionEvent event,
  ) {
    if (event.torrentId != state.torrentId) return state;

    switch (event) {
      case MetadataReceivedEvent():
        return state.copyWith(
          name: event.name.isNotEmpty ? event.name : state.name,
          hasMetadata: true,
          totalWanted: event.totalWanted > 0 ? event.totalWanted : state.totalWanted,
          files: event.files,
          stateLabel: state.isPaused ? 'Paused' : 'Downloading',
        );

      case TorrentPausedAlertEvent():
        return state.copyWith(
          isPaused: true,
          stateLabel: 'Paused',
          downloadRate: 0,
          uploadRate: 0,
        );

      case TorrentResumedAlertEvent():
        return state.copyWith(
          isPaused: false,
          stateLabel: state.isFinished ? 'Seeding' : 'Downloading',
          stoppedAnnounceReceived: false,
        );

      case PieceFinishedEvent():
        final newPiecesHave = event.piecesHave;
        final newPiecesTotal = event.piecesTotal > 0 ? event.piecesTotal : state.piecesTotal;
        final newProgress = state.totalWanted > 0
            ? (event.totalWantedDone / state.totalWanted).clamp(0.0, 1.0)
            : (newPiecesTotal > 0 ? (newPiecesHave / newPiecesTotal).clamp(0.0, 1.0) : state.progress);
        final isDone = newProgress >= 0.9999 || (newPiecesTotal > 0 && newPiecesHave >= newPiecesTotal);

        return state.copyWith(
          totalWantedDone: event.totalWantedDone,
          piecesHave: newPiecesHave,
          piecesTotal: newPiecesTotal,
          pieceBitfield: event.pieceBitfield.isNotEmpty ? event.pieceBitfield : state.pieceBitfield,
          progress: newProgress,
          isFinished: isDone,
          stateLabel: isDone ? (state.isPaused ? 'Finished' : 'Seeding') : state.stateLabel,
        );

      case SaveResumeDataCompletedEvent():
        return state;

      case TrackerReplyEvent():
        return state.copyWith(
          numPeers: event.numPeers > 0 ? event.numPeers : state.numPeers,
        );

      case TrackerErrorEvent():
        return state;

      case FastresumeRejectedEvent():
        return state.copyWith(
          errorMessage: 'Fastresume rejected: ${event.reason}',
        );

      case TorrentErrorAlertEvent():
        return state.copyWith(
          errorMessage: event.error,
          stateLabel: 'Error',
        );

      case StoppedAnnounceEvent():
        return state.copyWith(
          stoppedAnnounceReceived: true,
        );

      case FilePrioritiesChangedEvent():
        final newWanted = event.newTotalWanted;
        final newWantedDone = event.newTotalWantedDone;
        final newProgress = newWanted > 0
            ? (newWantedDone / newWanted).clamp(0.0, 1.0)
            : 1.0;

        return state.copyWith(
          filePriorities: event.priorities,
          totalWanted: newWanted,
          totalWantedDone: newWantedDone,
          progress: newProgress,
        );

      case StatusTickEvent():
        // Stats polling provides coarse rates and counts, while truth for wanted/pieces comes from native telemetry
        final isDone = event.progress >= 0.9999;
        final piecesHave = event.piecesHave > 0 ? event.piecesHave : state.piecesHave;
        final piecesTotal = event.piecesTotal > 0 ? event.piecesTotal : state.piecesTotal;

        return state.copyWith(
          progress: event.progress,
          downloadRate: event.downloadRate,
          uploadRate: event.uploadRate,
          totalDone: event.totalDone,
          totalWanted: event.totalWanted,
          totalWantedDone: event.totalWantedDone,
          numPeers: event.numPeers,
          numSeeds: event.numSeeds,
          stateLabel: event.stateLabel,
          fileProgress: event.fileProgress.isNotEmpty ? event.fileProgress : state.fileProgress,
          filePriorities: event.filePriorities.isNotEmpty ? event.filePriorities : state.filePriorities,
          pieceBitfield: event.piecesBitfield.isNotEmpty ? event.piecesBitfield : state.pieceBitfield,
          piecesHave: piecesHave,
          piecesTotal: piecesTotal,
          isFinished: isDone,
          isPaused: event.stateLabel.toLowerCase().contains('paused'),
        );
    }
  }
}
