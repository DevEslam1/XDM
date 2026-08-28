import 'package:dmx/core/domain/cycle_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CycleState domain tests', () {
    test('fromLibtorrent maps exact libtorrent state strings correctly', () {
      expect(CycleState.fromLibtorrent('downloading_metadata'),
          CycleState.fetchingMetadata);
      expect(CycleState.fromLibtorrent('allocating'), CycleState.allocating);
      expect(CycleState.fromLibtorrent('checking_files'), CycleState.verifying);
      expect(CycleState.fromLibtorrent('downloading'), CycleState.downloading);
      expect(CycleState.fromLibtorrent('finished'), CycleState.completed);
      expect(CycleState.fromLibtorrent('completed'), CycleState.completed);
      expect(CycleState.fromLibtorrent('paused'), CycleState.paused);
      expect(CycleState.fromLibtorrent('stalled'), CycleState.stalled);
      expect(CycleState.fromLibtorrent('error'), CycleState.failed);
      expect(CycleState.fromLibtorrent('resuming'), CycleState.resuming);
      expect(CycleState.fromLibtorrent('retrying'), CycleState.retrying);
      expect(CycleState.fromLibtorrent('muxing'), CycleState.merging);
    });

    test('fromLibtorrent handles seedingEnabled parameter correctly', () {
      expect(CycleState.fromLibtorrent('seeding', seedingEnabled: true),
          CycleState.seeding);
      expect(CycleState.fromLibtorrent('seeding', seedingEnabled: false),
          CycleState.completed);
      expect(
          CycleState.fromLibtorrent('stalled_uploading', seedingEnabled: true),
          CycleState.seeding);
    });

    test('fromLibtorrent falls back gracefully on null or empty input', () {
      expect(CycleState.fromLibtorrent(null), CycleState.downloading);
      expect(CycleState.fromLibtorrent(''), CycleState.downloading);
      expect(CycleState.fromLibtorrent('   '), CycleState.downloading);
    });

    test('fromLibtorrent fuzzy/substring matching works as expected', () {
      expect(CycleState.fromLibtorrent('is_seeding_now', seedingEnabled: true),
          CycleState.seeding);
      expect(CycleState.fromLibtorrent('is_seeding_now', seedingEnabled: false),
          CycleState.completed);
      expect(CycleState.fromLibtorrent('checking_resume_data_v2'),
          CycleState.verifying);
      expect(CycleState.fromLibtorrent('downloading_metadata_fast'),
          CycleState.fetchingMetadata);
      expect(CycleState.fromLibtorrent('stopped_by_user'), CycleState.paused);
      expect(CycleState.fromLibtorrent('error_disk_full'), CycleState.failed);
    });

    test('fromName correctly maps enum name', () {
      expect(CycleState.fromName('downloading'), CycleState.downloading);
      expect(CycleState.fromName('completed'), CycleState.completed);
      expect(CycleState.fromName('invalid_unknown'), isNull);
      expect(CycleState.fromName(null), isNull);
    });
  });
}
