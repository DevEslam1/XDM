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

    test('fromName handles snake_case, empties and fallback', () {
      expect(CycleState.fromName('fetching_metadata'),
          CycleState.fetchingMetadata);
      expect(
          CycleState.fromName('fetchingmetadata'), CycleState.fetchingMetadata);
      expect(CycleState.fromName('updating_links'), CycleState.updatingLinks);
      expect(CycleState.fromName('updatinglinks'), CycleState.updatingLinks);
      expect(CycleState.fromName('checking'), CycleState.verifying);
      expect(CycleState.fromName(''), isNull);
      expect(CycleState.fromName('   '), isNull);
      expect(CycleState.fromName('nope', fallback: CycleState.failed),
          CycleState.failed);
    });

    test('fromLibtorrent matches remaining map entries and starting states',
        () {
      expect(CycleState.fromLibtorrent('fetching_metadata'),
          CycleState.fetchingMetadata);
      expect(
          CycleState.fromLibtorrent('metadata'), CycleState.fetchingMetadata);
      expect(CycleState.fromLibtorrent('queued_for_checking'),
          CycleState.verifying);
      expect(CycleState.fromLibtorrent('checking'), CycleState.verifying);
      expect(CycleState.fromLibtorrent('failed'), CycleState.failed);
      expect(CycleState.fromLibtorrent('stopped'), CycleState.paused);
      expect(CycleState.fromLibtorrent('updating_links'),
          CycleState.updatingLinks);
      expect(
          CycleState.fromLibtorrent('updatinglinks'), CycleState.updatingLinks);
      expect(CycleState.fromLibtorrent('muxing'), CycleState.merging);
      expect(CycleState.fromLibtorrent('starting'), CycleState.starting);
      expect(CycleState.fromLibtorrent('queued'), CycleState.starting);
      expect(CycleState.fromLibtorrent('waiting_for_counterpart'),
          CycleState.starting);
      expect(
          CycleState.fromLibtorrent('stalled_downloading'), CycleState.stalled);
    });

    test('fromLibtorrent unknown states fall back to stalled', () {
      expect(
          CycleState.fromLibtorrent('some_unknown_state'), CycleState.stalled);
    });

    test('TorrentSourceException toString', () {
      const withUrl = TorrentSourceException('boom', url: 'https://x');
      expect(
          withUrl.toString(), 'TorrentSourceException: boom (url: https://x)');

      const noUrl = TorrentSourceException('boom');
      expect(noUrl.toString(), 'TorrentSourceException: boom');
      expect(noUrl.message, 'boom');
      expect(noUrl.url, isNull);
    });
  });
}
