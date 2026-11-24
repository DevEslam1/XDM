import 'package:dmx/core/domain/models/user_script.dart';
import 'package:dmx/core/domain/repositories/script_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeScriptRepository extends ChangeNotifier implements ScriptRepository {
  final List<UserScript> _scripts = [];
  String? toggledId;
  bool? toggledEnabled;
  String? deletedId;

  @override
  List<UserScript> get scripts => List.unmodifiable(_scripts);

  @override
  Future<void> load() async {}

  @override
  Future<void> add(UserScript script) async {
    _scripts.add(script);
  }

  @override
  Future<void> update(UserScript script) async {
    final i = _scripts.indexWhere((s) => s.id == script.id);
    if (i != -1) _scripts[i] = script;
  }

  @override
  Future<void> delete(String id) async {
    deletedId = id;
    _scripts.removeWhere((s) => s.id == id);
  }

  @override
  Future<void> toggle(String id, bool enabled) async {
    toggledId = id;
    toggledEnabled = enabled;
  }

  @override
  List<UserScript> scriptsForUrl(String url) =>
      _scripts.where((s) => s.urlPattern == url).toList();
}

void main() {
  group('ScriptRepository contract', () {
    test('can be implemented and exercised', () async {
      final repo = _FakeScriptRepository();
      const script = UserScript(
        id: '1',
        name: 'n',
        urlPattern: 'https://x',
        code: 'c',
      );

      await repo.load();
      await repo.add(script);
      expect(repo.scripts, hasLength(1));
      expect(repo.scriptsForUrl('https://x'), hasLength(1));
      expect(repo.scriptsForUrl('https://y'), isEmpty);

      await repo.update(
        script.copyWith(name: 'updated'),
      );
      expect(repo.scripts.first.name, 'updated');

      await repo.toggle('1', false);
      expect(repo.toggledId, '1');
      expect(repo.toggledEnabled, isFalse);

      await repo.delete('1');
      expect(repo.deletedId, '1');
      expect(repo.scripts, isEmpty);
    });

    test('notifies listeners', () {
      final repo = _FakeScriptRepository();
      var notified = false;
      repo.addListener(() => notified = true);
      repo.notifyListeners();
      expect(notified, isTrue);
    });
  });
}
