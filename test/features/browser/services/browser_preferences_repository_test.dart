import 'package:dmx/features/browser/data/browser_preferences_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BrowserPreferencesRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = BrowserPreferencesRepository();
  });

  group('BrowserPreferencesRepository Tests', () {
    test('getSnifferEnabled defaults to true and updates correctly', () async {
      expect(await repo.getSnifferEnabled(), isTrue);

      await repo.setSnifferEnabled(false);
      expect(await repo.getSnifferEnabled(), isFalse);

      await repo.setSnifferEnabled(true);
      expect(await repo.getSnifferEnabled(), isTrue);
    });

    test('getIncognitoBannerDismissed defaults to false and updates correctly',
        () async {
      expect(await repo.getIncognitoBannerDismissed(), isFalse);

      await repo.setIncognitoBannerDismissed(true);
      expect(await repo.getIncognitoBannerDismissed(), isTrue);
    });

    test('getCustomShortcuts returns empty list initially', () async {
      final shortcuts = await repo.getCustomShortcuts();
      expect(shortcuts, isEmpty);
    });

    test('saveCustomShortcuts persists and reads back shortcuts', () async {
      final sample = [
        {'title': 'Google', 'url': 'https://google.com'},
        {'title': 'GitHub', 'url': 'https://github.com'},
      ];

      await repo.saveCustomShortcuts(sample);
      final retrieved = await repo.getCustomShortcuts();

      expect(retrieved.length, equals(2));
      expect(retrieved[0]['title'], equals('Google'));
      expect(retrieved[1]['url'], equals('https://github.com'));
    });

    test('Custom constructor with injected SharedPreferences instance works',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final customRepo = BrowserPreferencesRepository(prefs);

      await customRepo.setSnifferEnabled(false);
      expect(await customRepo.getSnifferEnabled(), isFalse);
    });
  });
}
