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
    );
  }

  static bool _computeIsDone({
    required int totalWanted,
    required int totalWantedDone,
    required int piecesTotal,
    required int piecesHave,
    required double progress,
  }) {
    if (totalWanted > 0) {
      return totalWantedDone >= totalWanted;
    }
    if (piecesTotal > 0) {
      return piecesHave >= piecesTotal;
    }
    return progress >= 0.9999;
  }

  /// Pure event reducer producing the next immutable [TorrentSessionState].
  static TorrentSessionState reduce(
    TorrentSessionState state,
    TorrentSessionEvent event,
  ) {
    if (event.torrentId != state.torrentId) return state;

    switch (event) {
      case MetadataReceivedEvent():
        final newWanted =
            event.totalWanted > 0 ? event.totalWanted : state.totalWanted;
        final isDone = _computeIsDone(
          totalWanted: newWanted,
          totalWantedDone: state.totalWantedDone,
          piecesTotal: state.piecesTotal,
          piecesHave: state.piecesHave,
          progress: state.progress,
        );
        return state.copyWith(
          name: event.name.isNotEmpty ? event.name : state.name,
          hasMetadata: true,
          totalWanted: newWanted,
          files: event.files,
          isFinished: isDone,
          isSeeding: isDone && !state.isPaused,
          stateLabel: state.errorMessage != null
              ? 'Error'
              : (isDone
                  ? (state.isPaused ? 'Finished' : 'Seeding')
                  : (state.isPaused ? 'Paused' : 'Downloading')),
        );

      case TorrentPausedAlertEvent():
        return state.copyWith(
          isPaused: true,
          isSeeding: false,
          stateLabel: state.errorMessage != null
              ? 'Error'
              : (state.isFinished ? 'Finished' : 'Paused'),
          downloadRate: 0,
          uploadRate: 0,
        );

      case TorrentResumedAlertEvent():
        return state.copyWith(
          isPaused: false,
          isSeeding: state.isFinished,
          stateLabel: state.errorMessage != null
              ? 'Error'
              : (state.isFinished ? 'Seeding' : 'Downloading'),
        );

      case PieceFinishedEvent():
        final newPiecesHave = event.piecesHave;
        final newPiecesTotal =
            event.piecesTotal > 0 ? event.piecesTotal : state.piecesTotal;
        final effectiveTotalWanted = state.totalWanted;
        final effectiveWantedDone = event.totalWantedDone;

        final newProgress = effectiveTotalWanted > 0
            ? (effectiveWantedDone / effectiveTotalWanted).clamp(0.0, 1.0)
            : (newPiecesTotal > 0
                ? (newPiecesHave / newPiecesTotal).clamp(0.0, 1.0)
                : state.progress.clamp(0.0, 1.0));

        final isDone = _computeIsDone(
          totalWanted: effectiveTotalWanted,
          totalWantedDone: effectiveWantedDone,
          piecesTotal: newPiecesTotal,
          piecesHave: newPiecesHave,
          progress: newProgress,
        );

        final label = state.errorMessage != null
            ? 'Error'
            : (isDone
                ? (state.isPaused ? 'Finished' : 'Seeding')
                : (state.isPaused ? 'Paused' : 'Downloading'));

        return state.copyWith(
          totalWantedDone: event.totalWantedDone,
          piecesHave: newPiecesHave,
          piecesTotal: newPiecesTotal,
          pieceBitfield: event.pieceBitfield.isNotEmpty
              ? event.pieceBitfield
              : state.pieceBitfield,
          progress: newProgress,
          isFinished: isDone,
          isSeeding: isDone && !state.isPaused,
          stateLabel: label,
        );

      case SaveResumeDataCompletedEvent():
        return state;

      case TrackerReplyEvent():
        return state.copyWith(
          numPeers: event.numPeers >= 0 ? event.numPeers : state.numPeers,
        );

      case TrackerErrorEvent():
        return state;

      case FastresumeRejectedEvent():
        return state.copyWith(
          errorMessage: 'Fastresume rejected: ${event.reason}',
          isPaused: true,
          isSeeding: false,
          stateLabel: 'Error',
        );

      case TorrentErrorAlertEvent():
        return state.copyWith(
          errorMessage: event.error,
          isSeeding: false,
          stateLabel: 'Error',
        );

      case FilePrioritiesChangedEvent():
        final newWanted = event.newTotalWanted;
        final newWantedDone = event.newTotalWantedDone;
        final newProgress =
            newWanted > 0 ? (newWantedDone / newWanted).clamp(0.0, 1.0) : 1.0;
        final isDone = _computeIsDone(
          totalWanted: newWanted,
          totalWantedDone: newWantedDone,
          piecesTotal: state.piecesTotal,
          piecesHave: state.piecesHave,
          progress: newProgress,
        );

        return state.copyWith(
          filePriorities: event.priorities,
          totalWanted: newWanted,
          totalWantedDone: newWantedDone,
          progress: newProgress,
          isFinished: isDone,
          isSeeding: isDone && !state.isPaused,
          stateLabel: state.errorMessage != null
              ? 'Error'
              : (isDone
                  ? (state.isPaused ? 'Finished' : 'Seeding')
                  : (state.isPaused ? 'Paused' : 'Downloading')),
        );

      case StatusTickEvent():
        // Allow authoritative 0-values from native engine
        final piecesHave =
            event.piecesHave >= 0 ? event.piecesHave : state.piecesHave;
        final piecesTotal =
            event.piecesTotal >= 0 ? event.piecesTotal : state.piecesTotal;
        final totalWanted =
            event.totalWanted >= 0 ? event.totalWanted : state.totalWanted;
        final totalWantedDone = event.totalWantedDone >= 0
            ? event.totalWantedDone
            : state.totalWantedDone;

        final isDone = _computeIsDone(
          totalWanted: totalWanted,
          totalWantedDone: totalWantedDone,
          piecesTotal: piecesTotal,
          piecesHave: piecesHave,
          progress: event.progress,
        );

        final isPaused =
            event.stateLabel.toLowerCase().contains('paused') || state.isPaused;
        final isSeeding = isDone && !isPaused;
        final label = state.errorMessage != null
            ? 'Error'
            : (isDone
                ? (isPaused ? 'Finished' : 'Seeding')
                : (isPaused
                    ? 'Paused'
                    : (event.stateLabel.isNotEmpty
                        ? event.stateLabel
                        : 'Downloading')));

        return state.copyWith(
          progress: event.progress,
          downloadRate: event.downloadRate,
          uploadRate: event.uploadRate,
          totalDone: event.totalDone,
          totalWanted: totalWanted,
          totalWantedDone: totalWantedDone,
          numPeers: event.numPeers >= 0 ? event.numPeers : state.numPeers,
          numSeeds: event.numSeeds >= 0 ? event.numSeeds : state.numSeeds,
          stateLabel: label,
          fileProgress: event.fileProgress.isNotEmpty
              ? event.fileProgress
              : state.fileProgress,
          filePriorities: event.filePriorities.isNotEmpty
              ? event.filePriorities
              : state.filePriorities,
          pieceBitfield: event.piecesBitfield.isNotEmpty
              ? event.piecesBitfield
              : state.pieceBitfield,
          piecesHave: piecesHave,
          piecesTotal: piecesTotal,
          isFinished: isDone,
          isPaused: isPaused,
          isSeeding: isSeeding,
        );
    }
  }
}
