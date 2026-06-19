// ignore_for_file: avoid_print
// Test that the YoutubeService methods work with the fallback
import 'package:dmx/core/services/youtube_service.dart';
import 'package:logging/logging.dart';

void main() async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((e) {
    print('[${e.level.name}] ${e.loggerName}: ${e.message}');
    if (e.error != null) {
      print(e.error);
    }
  });

  final url = 'https://www.youtube.com/playlist?list=PLDoPjvoNmBAy532K9M_fjiAmrJ0gkCyLJ';

  print('=== YoutubeService.getPlaylistVideos ===');
  final videos = await YoutubeService.getPlaylistVideos(url);
  print('Total videos: ${videos.length}');
  for (var i = 0; i < videos.length && i < 5; i++) {
    final v = videos[i];
    print('  ${i + 1}. [${v['id']}] "${v['title']}" - ${v['duration']}s');
  }
  if (videos.length > 5) {
    print('  ... and ${videos.length - 5} more');
  }

  YoutubeService.close();
}
