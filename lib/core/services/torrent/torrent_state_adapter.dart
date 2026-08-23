import 'package:libtorrent_flutter/libtorrent_flutter.dart' as lt;
import '../../domain/torrent_models.dart';

// FIX-3.2: Adapter between libtorrent_flutter.TorrentState and domain DmxTorrentState
class TorrentStateAdapter {
  static DmxTorrentState fromLibtorrent(lt.TorrentState state) {
    switch (state) {
      case lt.TorrentState.error:
        return DmxTorrentState.error;
      case lt.TorrentState.checkingFiles:
        return DmxTorrentState.checkingFiles;
      case lt.TorrentState.downloadingMetadata:
        return DmxTorrentState.downloadingMetadata;
      case lt.TorrentState.downloading:
        return DmxTorrentState.downloading;
      case lt.TorrentState.finished:
        return DmxTorrentState.finished;
      case lt.TorrentState.seeding:
        return DmxTorrentState.seeding;
      case lt.TorrentState.allocating:
        return DmxTorrentState.allocating;
      case lt.TorrentState.checkingResume:
        return DmxTorrentState.checkingResume;
      case lt.TorrentState.unknown:
        return DmxTorrentState.unknown;
    }
  }

  static lt.TorrentState toLibtorrent(DmxTorrentState state) {
    switch (state) {
      case DmxTorrentState.error:
        return lt.TorrentState.error;
      case DmxTorrentState.checkingFiles:
        return lt.TorrentState.checkingFiles;
      case DmxTorrentState.downloadingMetadata:
        return lt.TorrentState.downloadingMetadata;
      case DmxTorrentState.downloading:
        return lt.TorrentState.downloading;
      case DmxTorrentState.finished:
        return lt.TorrentState.finished;
      case DmxTorrentState.seeding:
        return lt.TorrentState.seeding;
      case DmxTorrentState.allocating:
        return lt.TorrentState.allocating;
      case DmxTorrentState.checkingResume:
        return lt.TorrentState.checkingResume;
      case DmxTorrentState.unknown:
        return lt.TorrentState.unknown;
    }
  }
}
