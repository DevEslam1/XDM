class TorrentFileItem {
  final int index;
  final String name;
  final int size;
  TorrentFileItem({required this.index, required this.name, required this.size});
}

class TorrentUpdateInfo {
  final int id;
  final String name;
  final double progress;
  final int downloadRate;
  final int uploadRate;
  final int totalDone;
  final int totalWanted;
  final bool hasMetadata;
  final String stateLabel;
  final int numSeeds;
  final int numPeers;

  TorrentUpdateInfo({
    required this.id,
    required this.name,
    required this.progress,
    required this.downloadRate,
    required this.uploadRate,
    required this.totalDone,
    required this.totalWanted,
    required this.hasMetadata,
    required this.stateLabel,
    this.numSeeds = 0,
    this.numPeers = 0,
  });
}
