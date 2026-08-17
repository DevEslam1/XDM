// REMOVED: TorrentLifecycleManager was a dead duplicate of [TorrentProvider].
//
// It maintained a `Map<String, int> _torrentIds` identical to the one in
// [TorrentProvider] but was never instantiated or referenced anywhere in the
// codebase. All torrent ID registration/lookup is handled by:
//
//   • [TorrentProvider.registerTorrentId] / [TorrentProvider.unregisterTorrentId]
//   • [TorrentProvider.torrentIds] (the live map)
//
// If you need torrent lifecycle tracking, use [TorrentProvider] directly.
