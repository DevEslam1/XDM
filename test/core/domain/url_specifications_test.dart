import 'package:dmx/core/domain/utils/url_specifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UrlSpecifications P0 and Domain Specification Tests', () {
    test('isHttpUrl correctly validates HTTP and HTTPS schemes', () {
      expect(
          UrlSpecifications.isHttpUrl('https://example.com/file.zip'), isTrue);
      expect(
          UrlSpecifications.isHttpUrl('http://example.com/file.zip'), isTrue);
      expect(
          UrlSpecifications.isHttpUrl('ftp://example.com/file.zip'), isFalse);
      expect(UrlSpecifications.isHttpUrl(''), isFalse);
      expect(UrlSpecifications.isHttpUrl('   '), isFalse);
    });

    test(
        'P0-1: isTorrentFileUrl restricts file:// and content:// URIs to .torrent or MIME',
        () {
      // Valid torrent files
      expect(
          UrlSpecifications.isTorrentFileUrl('file:///sdcard/download.torrent'),
          isTrue);
      expect(
          UrlSpecifications.isTorrentFileUrl(
              'content://media/external/files/123.torrent'),
          isTrue);
      expect(
          UrlSpecifications.isTorrentFileUrl(
              'https://example.com/arch.torrent?pass=1'),
          isTrue);
      expect(
          UrlSpecifications.isTorrentFileUrl(
              'content://com.android.providers.media.documents/document/document%3A1000000035',
              mimeType: 'application/x-bittorrent'),
          isTrue);

      // Normal files via SAF / file / content (must NOT be treated as torrents)
      expect(
          UrlSpecifications.isTorrentFileUrl(
              'content://media/external/files/document.pdf'),
          isFalse);
      expect(
          UrlSpecifications.isTorrentFileUrl(
              'file:///storage/emulated/0/Download/photo.jpg'),
          isFalse);
      expect(
          UrlSpecifications.isTorrentFileUrl(
              'content://com.android.providers.media.documents/document/document%3A1000000035'),
          isFalse);
      expect(
          UrlSpecifications.isTorrentFileUrl('https://example.com/video.mp4'),
          isFalse);
    });

    test('P2-7: isMagnetUrl strict vs lenient mode', () {
      const v1Hex =
          'magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709&dn=test';
      const v1Base32 =
          'magnet:?xt=urn:btih:N46PXXS6NNVEMMRVV7XZKYAYBL65QBYJ&dn=test';
      const v2Hex64 =
          'magnet:?xt=urn:btmh:1220da39a3ee5e6b4b0d3255bfef95601890afd80709da39a3ee5e6b4b0d3255bfef&dn=test_v2';
      const trackerOnly =
          'magnet:?tr=http%3A%2F%2Ftracker.example.com%3A80%2Fannounce&dn=tracker_only';
      const invalidMagnet = 'magnet:?invalid=true';
      const notMagnet = 'https://example.com';

      // Strict mode (default)
      expect(UrlSpecifications.isMagnetUrl(v1Hex, strict: true), isTrue);
      expect(UrlSpecifications.isMagnetUrl(v1Base32, strict: true), isTrue);
      expect(UrlSpecifications.isMagnetUrl(v2Hex64, strict: true), isTrue);
      expect(UrlSpecifications.isMagnetUrl(trackerOnly, strict: true), isFalse);
      expect(
          UrlSpecifications.isMagnetUrl(invalidMagnet, strict: true), isFalse);
      expect(UrlSpecifications.isMagnetUrl(notMagnet, strict: true), isFalse);

      // Lenient mode
      expect(UrlSpecifications.isMagnetUrl(trackerOnly, strict: false), isTrue);
      expect(
          UrlSpecifications.isMagnetUrl(invalidMagnet, strict: false), isFalse);
    });

    test('resolveTorrentUriKind resolves Uri correctly', () {
      final magnetUri = Uri.parse(
          'magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709&dn=test');
      final torrentFileUri =
          Uri.parse('file:///storage/emulated/0/Download/ubuntu.torrent');
      final safPdfUri = Uri.parse(
          'content://com.android.providers.media.documents/document/document%3A1000000035');
      final safTorrentUri = Uri.parse(
          'content://com.android.providers.media.documents/document/document%3A1000000035');
      final httpUri = Uri.parse('https://example.com/file.zip');

      expect(UrlSpecifications.resolveTorrentUriKind(magnetUri),
          TorrentUriKind.magnet);
      expect(UrlSpecifications.resolveTorrentUriKind(torrentFileUri),
          TorrentUriKind.torrentFile);
      expect(UrlSpecifications.resolveTorrentUriKind(safPdfUri),
          TorrentUriKind.notTorrent);
      expect(
          UrlSpecifications.resolveTorrentUriKind(safTorrentUri,
              mimeType: 'application/x-bittorrent'),
          TorrentUriKind.torrentFile);
      expect(UrlSpecifications.resolveTorrentUriKind(httpUri),
          TorrentUriKind.notTorrent);
    });

    test('isHttpUrl trims and rejects malformed/hostless urls', () {
      expect(UrlSpecifications.isHttpUrl('  https://example.com/a  '), isTrue);
      expect(UrlSpecifications.isHttpUrl('https://'), isFalse);
      expect(UrlSpecifications.isHttpUrl('not a url'), isFalse);
      expect(UrlSpecifications.isHttpUrl('http:///path'), isFalse);
    });

    test('isTorrentFileUrl handles query/fragment and mime edge cases', () {
      expect(UrlSpecifications.isTorrentFileUrl('https://x/a.torrent#frag'),
          isTrue);
      expect(UrlSpecifications.isTorrentFileUrl('file:///x/a.torrent?q=1'),
          isTrue);
      expect(UrlSpecifications.isTorrentFileUrl('content://x/a.torrent#frag'),
          isTrue);
      expect(
          UrlSpecifications.isTorrentFileUrl('https://x/a.bin',
              mimeType: ' APPLICATION/X-BITTORRENT '),
          isTrue);
      expect(UrlSpecifications.isTorrentFileUrl('https://x/a.bin'), isFalse);
    });

    test('isMagnetUrl handles btmh multihash prefix', () {
      const btmh =
          'magnet:?xt=urn:btmh:1220DA39A3EE5E6B4B0D3255BFEF95601890AFD80709DA39A3EE5E6B4B0D3255BFEF&dn=x';
      expect(UrlSpecifications.isMagnetUrl(btmh), isTrue);
      expect(UrlSpecifications.isMagnetUrl('not-a-magnet'), isFalse);
    });

    test('isValidTransmissionUrl accepts http, magnet and torrent file', () {
      expect(
          UrlSpecifications.isValidTransmissionUrl('https://x/a.zip'), isTrue);
      expect(
          UrlSpecifications.isValidTransmissionUrl(
              'magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709'),
          isTrue);
      expect(UrlSpecifications.isValidTransmissionUrl('file:///x/a.torrent'),
          isTrue);
      expect(UrlSpecifications.isValidTransmissionUrl('ftp://x/a'), isFalse);
    });

    test('parseMagnetUrl extracts name, hash and trackers', () {
      final parsed = UrlSpecifications.parseMagnetUrl(
        'magnet:?dn=My%20File&xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709'
        '&xt=urn:btmh:1220da39a3ee5e6b4b0d3255bfef95601890afd80709'
        '&tr=http%3A%2F%2Ftracker.example.com',
      );
      expect(parsed['name'], 'My File');
      expect(parsed['infoHash'], 'DA39A3EE5E6B4B0D3255BFEF95601890AFD80709');
      expect(parsed['trackers'], ['http://tracker.example.com']);

      final empty = UrlSpecifications.parseMagnetUrl('magnet:');
      expect(empty['infoHash'], isNull);
      expect(empty['trackers'], isEmpty);
    });

    test('TorrentFileSelection toMap/fromMap/copyWith', () {
      const sel = TorrentFileSelection(
        index: 1,
        path: 'a/b.mp4',
        size: 100,
        selected: false,
      );
      final map = sel.toMap();
      expect(map['index'], 1);
      expect(map['selected'], isFalse);

      final restored = TorrentFileSelection.fromMap(map);
      expect(restored.index, 1);
      expect(restored.path, 'a/b.mp4');
      expect(restored.size, 100);
      expect(restored.selected, isFalse);

      final defaults = TorrentFileSelection.fromMap(const {});
      expect(defaults.index, 0);
      expect(defaults.path, '');
      expect(defaults.size, 0);
      expect(defaults.selected, isTrue);

      final copied = sel.copyWith(index: 9, selected: true);
      expect(copied.index, 9);
      expect(copied.selected, isTrue);
      expect(copied.path, 'a/b.mp4');
      expect(sel.copyWith().index, 1);
    });

    test('UrlResourceMetadata copyWith overrides and preserves', () {
      const meta = UrlResourceMetadata(
        url: 'https://x/a',
        fileName: 'a',
        extension: 'zip',
        fileSize: 1,
        category: 'Archive',
        isTorrent: false,
        torrentInfoHash: 'h',
        audioUrl: 'aud',
        audioSize: 2,
        thumbnailUrl: 'thumb',
        torrentFiles: [
          TorrentFileSelection(index: 0, path: 'p', size: 1),
        ],
      );
      final updated = meta.copyWith(
        url: 'u',
        fileName: 'b',
        extension: 'mp4',
        fileSize: 9,
        category: 'Video',
        isTorrent: true,
        torrentInfoHash: 'h2',
        audioUrl: 'aud2',
        audioSize: 3,
        thumbnailUrl: 'thumb2',
        torrentFiles: const [],
      );
      expect(updated.url, 'u');
      expect(updated.fileName, 'b');
      expect(updated.extension, 'mp4');
      expect(updated.isTorrent, isTrue);
      expect(updated.audioSize, 3);
      expect(updated.torrentFiles, isEmpty);

      final unchanged = meta.copyWith();
      expect(unchanged.fileName, 'a');
      expect(unchanged.category, 'Archive');
    });
  });
}
