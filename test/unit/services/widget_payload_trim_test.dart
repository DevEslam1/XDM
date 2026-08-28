import 'dart:convert';
import 'package:dmx/core/services/widget_data_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Widget Payload Trim Tests [W-8]', () {
    test(
        'WidgetTaskSummary.toJson excludes unrendered fields to minimize payload size',
        () {
      const summary = WidgetTaskSummary(
        id: 'task_1',
        fileName: 'video.mp4',
        status: 'downloading',
        progress: 0.75,
        speedBytesPerSec: 1048576,
        fileSizeBytes: 104857600,
        downloadedBytes: 78643200,
        category: 'Video',
        thumbnailUrl: 'https://example.com/thumb.jpg',
        playlistId: 'pl_123',
        playlistTitle: 'Playlist Title',
        playlistIndex: 1,
        errorMessage: 'Network timeout',
        isTorrent: false,
        seedingRatio: 1.5,
        priority: 5,
        isAppUpdate: false,
        speedTrend: 'up',
      );

      final json = summary.toJson();
      final jsonStr = jsonEncode(json);

      // Rendered fields must be present
      expect(json['id'], equals('task_1'));
      expect(json['fileName'], equals('video.mp4'));
      expect(json['status'], equals('downloading'));
      expect(json['progress'], equals(0.75));
      expect(json['speedBytesPerSec'], equals(1048576));
      expect(json['fileSizeBytes'], equals(104857600));
      expect(json['downloadedBytes'], equals(78643200));
      expect(json['category'], equals('Video'));
      expect(json['isTorrent'], equals(false));
      expect(json['isAppUpdate'], equals(false));
      expect(json['speedTrend'], equals('up'));

      // Unrendered fields must NOT be in JSON
      expect(json.containsKey('thumbnailUrl'), isFalse);
      expect(json.containsKey('playlistId'), isFalse);
      expect(json.containsKey('playlistTitle'), isFalse);
      expect(json.containsKey('playlistIndex'), isFalse);
      expect(json.containsKey('errorMessage'), isFalse);
      expect(json.containsKey('seedingRatio'), isFalse);
      expect(json.containsKey('priority'), isFalse);

      expect(jsonStr.contains('thumbnailUrl'), isFalse);
    });
  });
}
