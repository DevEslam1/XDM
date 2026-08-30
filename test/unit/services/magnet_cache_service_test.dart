import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/magnet_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MagnetCacheService', () {
    test('cacheMetadata and getCachedMetadata roundtrip', () async {
      final infoHash = 'c12fe1c06bba254a9dc9f519b335aa7c1367a88a';
      final metadata = {
        'name': 'Ubuntu 24.04 Desktop ISO',
        'size': 5000000000,
        'fileCount': 1,
      };

      await MagnetCacheService.cacheMetadata(infoHash, metadata);
      final retrieved = await MagnetCacheService.getCachedMetadata(infoHash);

      expect(retrieved, isNotNull);
      expect(retrieved!['name'], equals('Ubuntu 24.04 Desktop ISO'));
      expect(retrieved['size'], equals(5000000000));
    });

    test('getCachedMetadata returns null for uncached infoHash', () async {
      final retrieved =
          await MagnetCacheService.getCachedMetadata('non_existent_hash');
      expect(retrieved, isNull);
    });
  });
}
