import 'package:dmx/core/domain/cycle_state.dart';
import 'package:dmx/core/services/engine/cycle_state_resolver.dart';
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
    test(
        'LRU cache retains capacity up to 256 and evicts oldest rather than clearing all',
        () {
      // Fill cache with 256 distinct messages
      for (var i = 0; i < 256; i++) {
        CycleStateResolver.resolve(statusMessage: 'Downloading chunk #$i');
      }
      expect(CycleStateResolver.cacheSizeForTesting, equals(256));

      // 257th entry triggers LRU eviction of the oldest entry (chunk #0)
      CycleStateResolver.resolve(statusMessage: 'Downloading chunk #256');
      expect(CycleStateResolver.cacheSizeForTesting, equals(256));

      // Subsequent access to #256 is cached
      final state =
          CycleStateResolver.resolve(statusMessage: 'Downloading chunk #256');
      expect(state, equals(CycleState.downloading));
    });
  });
}
