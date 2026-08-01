class TorrentFileItem {
  final int index;
  final String name;
  final int size;
  final int downloadedBytes;
  final int priority;
  final bool selected;

  TorrentFileItem({
    required this.index,
    required this.name,
    required this.size,
    this.downloadedBytes = 0,
    this.priority = 4,
    this.selected = true,
  });
}

class TorrentUpdateInfo {
  final int id;
  final String name;
  final double progress;
  final int downloadRate;
  final int uploadRate;
  final int totalDone;
  final int totalWanted;
  final int totalWantedDone;
  final bool hasMetadata;
  final String stateLabel;
  final int numSeeds;
  final int numPeers;
  final int piecesHave;
  final int piecesTotal;
  final int downloadPayloadRate;
  final int uploadPayloadRate;
  final int totalPayloadDownload;
  final int totalPayloadUpload;
  final String currentTracker;
  final int nextAnnounceSeconds;
  final double distributedCopies;
  final List<int> fileProgress;
  final List<int> filePriorities;

  TorrentUpdateInfo({
    required this.id,
    required this.name,
    required this.progress,
    required this.downloadRate,
    required this.uploadRate,
    required this.totalDone,
    required this.totalWanted,
    required this.totalWantedDone,
    required this.hasMetadata,
    required this.stateLabel,
    this.numSeeds = 0,
    this.numPeers = 0,
    this.piecesHave = 0,
    this.piecesTotal = 0,
    this.downloadPayloadRate = 0,
    this.uploadPayloadRate = 0,
    this.totalPayloadDownload = 0,
    this.totalPayloadUpload = 0,
    this.currentTracker = '',
    this.nextAnnounceSeconds = 0,
    this.distributedCopies = 0.0,
    List<int> fileProgress = const [],
    List<int> filePriorities = const [],
  })  : fileProgress = List.unmodifiable(fileProgress),
        filePriorities = List.unmodifiable(filePriorities);
}