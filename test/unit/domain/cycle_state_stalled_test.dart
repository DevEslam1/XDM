import 'package:dmx/core/domain/cycle_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CycleState.fromLibtorrent Unknown Label Remediation (P1-4)', () {
    test('returns CycleState.stalled for unknown labels to surface failures', () {
      expect(CycleState.fromLibtorrent('corrupt_internal_state'), CycleState.stalled);
      expect(CycleState.fromLibtorrent('unrecognized_engine_code'), CycleState.stalled);
      expect(CycleState.fromLibtorrent('stuck_tracker_lookup'), CycleState.stalled);
    });

    test('correctly maps known active and terminal labels', () {
      expect(CycleState.fromLibtorrent('downloading'), CycleState.downloading);
      expect(CycleState.fromLibtorrent('downloading_metadata'), CycleState.fetchingMetadata);
      expect(CycleState.fromLibtorrent('allocating'), CycleState.allocating);
      expect(CycleState.fromLibtorrent('checking_files'), CycleState.verifying);
      expect(CycleState.fromLibtorrent('finished'), CycleState.completed);
      expect(CycleState.fromLibtorrent('paused'), CycleState.paused);
      expect(CycleState.fromLibtorrent('error'), CycleState.failed);
      expect(CycleState.fromLibtorrent('stalled'), CycleState.stalled);
    });

    test('handles empty and null labels gracefully', () {
      expect(CycleState.fromLibtorrent(null), CycleState.downloading);
      expect(CycleState.fromLibtorrent(''), CycleState.downloading);
      expect(CycleState.fromLibtorrent('   '), CycleState.downloading);
    });
  });
}
