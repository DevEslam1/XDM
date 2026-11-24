import 'package:dmx/core/models/xdm_backend_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiException.userMessage', () {
    test('maps sign-in errors', () {
      final e = ApiException(403, 'Please Sign in to confirm your age');
      expect(e.userMessage, 'YouTube requires sign-in. Try again later.');
      expect(e.toString(), contains('ApiException(403)'));
    });

    test('maps age-restriction errors', () {
      for (final body in [
        'age-restricted',
        'age restricted',
        'confirm your age',
        'age_gate',
        'agegate',
      ]) {
        expect(ApiException(400, body).userMessage,
            'This video is age-restricted.');
      }
    });

    test('maps geo-restriction errors', () {
      for (final body in [
        'geo-restricted',
        'geo restricted',
        'geo_blocked',
        'geo-blocked',
        'not available in your country',
        'not available in your region',
        'not available in your area',
      ]) {
        expect(ApiException(400, body).userMessage,
            'This video is not available in your region.');
      }
    });

    test('maps missing-stream errors', () {
      expect(ApiException(500, 'No streams found').userMessage,
          'No downloadable streams found.');
      expect(ApiException(500, 'no downloadable').userMessage,
          'No downloadable streams found.');
    });

    test('falls back to a generic message', () {
      final e = ApiException(418, 'teapot');
      expect(e.userMessage, 'Error 418: teapot');
    });
  });

  group('StreamEntry', () {
    test('fromJson reads all fields and defaults', () {
      final entry = StreamEntry.fromJson({
        'type': 'video_only',
        'quality': '1080p',
        'label': 'Full HD',
        'src': 'https://cdn/video.mp4',
        'audioSrc': 'https://cdn/audio.m4a',
        'videoSize': 1000,
        'audioSize': 200,
        'size': 1200,
        'ext': 'mkv',
        'format_id': '137',
        'videoId': 'vid1',
        'manifestType': 'dash',
      });
      expect(entry.type, 'video_only');
      expect(entry.quality, '1080p');
      expect(entry.label, 'Full HD');
      expect(entry.src, 'https://cdn/video.mp4');
      expect(entry.audioSrc, 'https://cdn/audio.m4a');
      expect(entry.videoSize, 1000);
      expect(entry.audioSize, 200);
      expect(entry.size, 1200);
      expect(entry.ext, 'mkv');
      expect(entry.formatId, '137');
      expect(entry.videoId, 'vid1');
      expect(entry.manifestType, 'dash');
      expect(entry.isPlayable, isFalse);
      expect(entry.needsMuxing, isTrue);
    });

    test('fromJson applies defaults and parses numeric strings', () {
      final entry = StreamEntry.fromJson({
        'videoSize': '2048',
        'audioSize': 1.9,
        'size': 'not-a-number',
        'formatId': 'fallback',
      });
      expect(entry.type, '');
      expect(entry.quality, '');
      expect(entry.label, '');
      expect(entry.src, '');
      expect(entry.audioSrc, isNull);
      expect(entry.videoId, isNull);
      expect(entry.videoSize, 2048);
      expect(entry.audioSize, 1);
      expect(entry.size, 0);
      expect(entry.ext, 'mp4');
      expect(entry.formatId, 'fallback');
      expect(entry.manifestType, '');
      expect(entry.isPlayable, isFalse);
      expect(entry.needsMuxing, isFalse);
    });

    test('isPlayable is true for combined and muxed', () {
      expect(
        StreamEntry.fromJson({'type': 'combined'}).isPlayable,
        isTrue,
      );
      expect(
        StreamEntry.fromJson({'type': 'muxed'}).isPlayable,
        isTrue,
      );
    });

    test('toJson round-trips and omits absent optional fields', () {
      final entry = StreamEntry(
        type: 'combined',
        quality: '720p',
        label: 'HD',
        src: 'https://cdn/a.mp4',
        videoSize: 10,
        audioSize: 0,
        size: 10,
        ext: 'mp4',
        formatId: '22',
        manifestType: '',
      );
      final json = entry.toJson();
      expect(json['type'], 'combined');
      expect(json.containsKey('audioSrc'), isFalse);
      expect(json.containsKey('videoId'), isFalse);
      expect(json['format_id'], '22');

      final restored = StreamEntry.fromJson(json);
      expect(restored.quality, '720p');
      expect(restored.isPlayable, isTrue);
    });
  });

  group('VideoStreams', () {
    test('fromJson parses streams and optional id', () {
      final streams = VideoStreams.fromJson({
        'url': 'https://youtube.com/watch?v=abc',
        'title': 'A video',
        'id': 'abc',
        'streams': [
          {'type': 'combined', 'quality': '360p'},
        ],
      });
      expect(streams.url, 'https://youtube.com/watch?v=abc');
      expect(streams.title, 'A video');
      expect(streams.id, 'abc');
      expect(streams.streams.length, 1);
      expect(streams.streams.first.type, 'combined');
    });

    test('fromJson tolerates missing fields', () {
      final streams = VideoStreams.fromJson({});
      expect(streams.url, '');
      expect(streams.title, '');
      expect(streams.id, isNull);
      expect(streams.streams, isEmpty);
    });

    test('toJson includes id only when present', () {
      final withId = VideoStreams(
        url: 'u',
        title: 't',
        id: 'i',
        streams: const [],
      );
      expect(withId.toJson()['id'], 'i');

      final withoutId = VideoStreams(url: 'u', title: 't', streams: const []);
      expect(withoutId.toJson().containsKey('id'), isFalse);
    });
  });

  group('PlaylistInfo', () {
    test('fromJson prefers the nested info map', () {
      final info = PlaylistInfo.fromJson({
        'info': {'title': 'My List', 'author': 'Me', 'videoCount': 3},
        'note': 'a note',
        'videos': [
          {'id': 'v1', 'title': 'One', 'duration': 90},
        ],
      });
      expect(info.title, 'My List');
      expect(info.author, 'Me');
      expect(info.videoCount, 3);
      expect(info.note, 'a note');
      expect(info.videos.length, 1);
      expect(info.videos.first.id, 'v1');
      expect(info.videos.first.selected, isTrue);
    });

    test('fromJson falls back to flat fields and numeric strings', () {
      final info = PlaylistInfo.fromJson({
        'title': 'Flat',
        'author': 'Someone',
        'videoCount': '5',
      });
      expect(info.title, 'Flat');
      expect(info.author, 'Someone');
      expect(info.videoCount, 5);
      expect(info.note, isNull);
      expect(info.videos, isEmpty);
    });

    test('fromJson tolerates a missing info map entirely', () {
      final info = PlaylistInfo.fromJson({'videos': []});
      expect(info.title, '');
      expect(info.author, '');
      expect(info.videoCount, 0);
    });

    test('toJson nests info and omits note when null', () {
      final info = PlaylistInfo(
        title: 'T',
        author: 'A',
        videoCount: 2,
        videos: const [],
      );
      final json = info.toJson();
      expect((json['info'] as Map)['title'], 'T');
      expect(json.containsKey('note'), isFalse);

      final withNote = PlaylistInfo(
        title: 'T',
        author: 'A',
        videoCount: 1,
        note: 'n',
        videos: const [],
      );
      expect(withNote.toJson()['note'], 'n');
    });
  });

  group('PlaylistVideo', () {
    test('fromJson reads fields and respects selected', () {
      final video = PlaylistVideo.fromJson({
        'id': 'x',
        'title': 'Title',
        'author': 'Author',
        'thumbnailUrl': 'thumb',
        'url': 'url',
        'duration': 120,
        'selected': false,
      });
      expect(video.id, 'x');
      expect(video.duration, 120);
      expect(video.selected, isFalse);

      final restored = PlaylistVideo.fromJson(video.toJson());
      expect(restored.selected, isFalse);
      expect(restored.thumbnailUrl, 'thumb');
    });

    test('fromJson defaults selected to true and numeric strings parse', () {
      final video = PlaylistVideo.fromJson({'duration': '75'});
      expect(video.selected, isTrue);
      expect(video.duration, 75);
      expect(video.id, '');
    });

    test('the public constructor stores every field', () {
      final video = PlaylistVideo(
        id: 'id',
        title: 'Title',
        author: 'Author',
        thumbnailUrl: 'thumb',
        url: 'url',
        duration: 5,
        selected: false,
      );
      expect(video.id, 'id');
      expect(video.title, 'Title');
      expect(video.author, 'Author');
      expect(video.thumbnailUrl, 'thumb');
      expect(video.url, 'url');
      expect(video.duration, 5);
      expect(video.selected, isFalse);
    });
  });

  group('SearchResult', () {
    test('fromJson and toJson round-trip', () {
      final result = SearchResult.fromJson({
        'id': 's1',
        'title': 'Song',
        'author': 'Artist',
        'thumbnailUrl': 'thumb',
        'url': 'url',
        'duration': '210',
      });
      expect(result.id, 's1');
      expect(result.duration, 210);
      expect(result.toJson()['title'], 'Song');
    });

    test('fromJson tolerates missing fields', () {
      final result = SearchResult.fromJson({});
      expect(result.id, '');
      expect(result.duration, 0);
      expect(result.toJson()['url'], '');
    });

    test('the public constructor stores every field', () {
      final result = SearchResult(
        id: 'id',
        title: 'Title',
        author: 'Author',
        thumbnailUrl: 'thumb',
        url: 'url',
        duration: 42,
      );
      expect(result.id, 'id');
      expect(result.title, 'Title');
      expect(result.author, 'Author');
      expect(result.thumbnailUrl, 'thumb');
      expect(result.url, 'url');
      expect(result.duration, 42);
    });
  });
}
