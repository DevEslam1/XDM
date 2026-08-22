/// libtorrent_flutter — Native libtorrent 2.1.1 bindings for Flutter.
///
/// Provides torrent downloading, file selection, and a built-in HTTP streaming
/// server for instant video playback from torrent sources.
library;

export 'src/ffi_bindings.dart'
    show BridgeAbiReport, kExpectedBridgeAbi, kExpectedStatusSize;
export 'src/libtorrent_flutter_base.dart';
export 'src/models.dart';
