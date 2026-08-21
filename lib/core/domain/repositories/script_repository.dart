import 'package:flutter/foundation.dart';
import '../models/user_script.dart';

/// Clean Architecture interface for user script operations.
abstract class ScriptRepository implements Listenable {
  List<UserScript> get scripts;
  Future<void> load();
  Future<void> add(UserScript script);
  Future<void> update(UserScript script);
  Future<void> delete(String id);
  Future<void> toggle(String id, bool enabled);
  List<UserScript> scriptsForUrl(String url);
}
