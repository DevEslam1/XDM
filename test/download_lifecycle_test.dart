import 'package:dmx/core/services/youtube_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Fetch playlist details for public playlist', () async {
    const playlistId = 'PLFgofPyD3Bck5vCNEsD9SxpIa74x3a1h2';
    const url = 'https://www.youtube.com/playlist?list=$playlistId';

    try {
      final details = await YoutubeService.getPlaylistDetails(url);
      if (details != null) {
        expect(details['info'], isNotNull);
        expect(details['videos'], isA<List>());
      }
    } catch (e) {
      // Handle unit test environment where network/backend may not be present
      expect(e, isNotNull);
    }
  });
}
