import 'package:dmx/core/services/youtube_service.dart';

void main() async {
  // Let's test getPlaylistDetails for a public playlist
  final playlistId = 'PLFgofPyD3Bck5vCNEsD9SxpIa74x3a1h2';
  final url = 'https://www.youtube.com/playlist?list=$playlistId';

  print('Fetching playlist details for $url...');
  final details = await YoutubeService.getPlaylistDetails(url);
  if (details == null) {
    print('Failed to fetch playlist details.');
    return;
  }

  final info = details['info'] as Map;
  final videos = details['videos'] as List;

  print('Playlist Info:');
  print('  Title: ${info['title']}');
  print('  Author: ${info['author']}');
  print('  Video Count: ${info['videoCount']}');
  print('  Parsed Videos Count: ${videos.length}');

  if (videos.isNotEmpty) {
    print('First 5 videos:');
    for (int i = 0; i < videos.length.clamp(0, 5); i++) {
      final video = videos[i] as Map;
      print(
        '  #${i + 1}: ID=${video['id']}, Title=${video['title']}, Author=${video['author']}, Duration=${video['duration']}s',
      );
    }
  }
}
