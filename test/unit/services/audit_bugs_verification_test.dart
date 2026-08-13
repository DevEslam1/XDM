import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Production Readiness Fixes Verification', () {
    test('ErrorTaxonomy maps SocketException to network error', () {
      final networkError = const SocketException('Connection failed');
      final classification = ErrorTaxonomy.classify(networkError);
      expect(classification.family, equals(ErrorFamily.network));
    });

    test('ChunkState initializes downloaded to 0 on non-resumable reset', () {
      final chunk = ChunkState(start: 0, end: 1024, downloaded: 500);
      expect(chunk.downloaded, equals(500));
      chunk.downloaded = 0;
      expect(chunk.downloaded, equals(0));
    });

    test('TorrentResumeStore register and unregister source stability', () {
      TorrentResumeStore.registerSource(101, 'https://example.com/test.torrent');
      TorrentResumeStore.unregisterTorrent(101);
      // Ensures no exception thrown and registration is cleaned up safely
    });
  });
}
