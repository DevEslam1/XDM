import 'package:dmx/core/domain/cycle_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CycleState mapper', () {
    test('maps libtorrent state strings to CycleState accurately', () {
      expect(CycleState.fromLibtorrent('downloading_metadata'),
          CycleState.fetchingMetadata);
      expect(CycleState.fromLibtorrent('allocating'), CycleState.allocating);
      expect(CycleState.fromLibtorrent('checking_files'), CycleState.verifying);
      expect(CycleState.fromLibtorrent('checking_resume_data'),
          CycleState.verifying);
      expect(CycleState.fromLibtorrent('queued_for_checking'),
          CycleState.verifying);
      expect(CycleState.fromLibtorrent('downloading'), CycleState.downloading);
      expect(CycleState.fromLibtorrent('finished'), CycleState.completed);
      expect(CycleState.fromLibtorrent('seeding'), CycleState.seeding);
      expect(CycleState.fromLibtorrent('paused'), CycleState.paused);
      expect(CycleState.fromLibtorrent('stalled'), CycleState.stalled);
      expect(CycleState.fromLibtorrent('error'), CycleState.failed);
      expect(CycleState.fromLibtorrent('updating_links'),
          CycleState.updatingLinks);
      expect(CycleState.fromLibtorrent('resuming'), CycleState.resuming);
      expect(CycleState.fromLibtorrent('merging'), CycleState.merging);
    });

    test('handles null and unknown labels gracefully', () {
      expect(CycleState.fromLibtorrent(null), CycleState.downloading);
      expect(CycleState.fromLibtorrent(''), CycleState.downloading);
      expect(
          CycleState.fromLibtorrent('some_random_state'), CycleState.stalled);
    });

    test('parses names in camelCase and snake_case', () {
      expect(
          CycleState.fromName('fetchingMetadata'), CycleState.fetchingMetadata);
      expect(CycleState.fromName('fetching_metadata'),
          CycleState.fetchingMetadata);
      expect(CycleState.fromName('updatingLinks'), CycleState.updatingLinks);
      expect(CycleState.fromName('updating_links'), CycleState.updatingLinks);
      expect(CycleState.fromName('checking'), CycleState.verifying);
      expect(CycleState.fromName('non_existent', fallback: CycleState.paused),
          CycleState.paused);
    });
  });
}
