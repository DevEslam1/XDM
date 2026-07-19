import 'package:dmx/core/services/youtube_service.dart'; void main() async { final stream = await YoutubeService.getStreamForVideo('dQw4w9WgXcQ', 'best_combined'); print(stream); }
