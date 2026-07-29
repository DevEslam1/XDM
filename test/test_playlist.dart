// ignore_for_file: avoid_print, avoid_dynamic_calls
import 'package:dmx/core/services/youtube_service.dart';

void main() async {
  final details = await YoutubeService.getPlaylistDetails(
    'https://www.youtube.com/playlist?list=PLFgofPyD3Bck5vCNEsD9SxpIa74x3a1h2',
  );
  print('Videos count: ${details?["videos"]?.length}');
}
