import 'package:dmx/core/services/engine/cycle_state_resolver.dart';
import 'package:dmx/features/downloads/models/cycle_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CycleStateResolver.clearCacheForTesting();
  });

  tearDown(() {
    CycleStateResolver.clearCacheForTesting();
  });

  group('CycleStateResolver LRU Eviction (Sprint 1)', () {
    test('LRU cache retains capacity up to 512 and evicts oldest rather than clearing all', () {
      // Fill cache with 512 distinct messages
      for (var i = 0; i < 512; i++) {
        CycleStateResolver.resolve(statusMessage: 'Downloading chunk #$i');
      }
      expect(CycleStateResolver.cacheSizeForTesting, equals(512));

      // 513th entry triggers LRU eviction of the oldest entry (chunk #0)
      CycleStateResolver.resolve(statusMessage: 'Downloading chunk #512');
      expect(CycleStateResolver.cacheSizeForTesting, equals(512));

      // Subsequent access to #512 is cached
      final state = CycleStateResolver.resolve(statusMessage: 'Downloading chunk #512');
      expect(state, equals(CycleState.downloading));
    });
  });
}
