import 'package:dmx/core/di/injection.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/permission_service.dart';
import 'package:dmx/core/services/shared_prefs_batcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetDependenciesForTesting();
  });

  tearDown(() async {
    await shutdownDependencies();
  });

  group('inject', () {
    test('resolves a manually registered singleton', () async {
      getIt.registerSingleton<String>('value');
      expect(inject<String>(), 'value');
    });
  });

  group('configureDependencies', () {
    test('registers the dependency graph and is idempotent', () async {
      await configureDependencies();
      expect(getIt.isRegistered<DatabaseService>(), isTrue);

      await configureDependencies();
      expect(getIt.isRegistered<DatabaseService>(), isTrue);
    });

    test('resolves dependency-free singletons lazily', () async {
      await configureDependencies();
      expect(getIt<StateStoreFactory>(), isA<StateStoreFactory>());
      expect(getIt<PermissionService>(), isA<PermissionService>());
      expect(getIt<SharedPrefsBatcher>(), isA<SharedPrefsBatcher>());
    });
  });

  group('shutdownDependencies', () {
    test('resets the graph', () async {
      await configureDependencies();
      expect(getIt.isRegistered<DatabaseService>(), isTrue);

      await shutdownDependencies();
      expect(getIt.isRegistered<DatabaseService>(), isFalse);
    });

    test('is safe to call on an empty graph', () async {
      await shutdownDependencies();
      expect(getIt.isRegistered<DatabaseService>(), isFalse);
    });
  });
}
