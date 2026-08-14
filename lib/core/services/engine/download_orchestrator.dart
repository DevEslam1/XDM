import 'metadata_resolver.dart';
import 'torrent_download_handler.dart';

// FIX: P0-01 — DownloadOrchestrator coordinates transfer jobs & delegators

class EngineDownloadOrchestrator {
  final TorrentDownloadHandler torrentHandler;
  final MetadataResolver metadataResolver;

  EngineDownloadOrchestrator({
    TorrentDownloadHandler? torrentHandler,
    MetadataResolver? metadataResolver,
  })  : torrentHandler = torrentHandler ?? TorrentDownloadHandler(),
        metadataResolver = metadataResolver ?? const MetadataResolver();
}
