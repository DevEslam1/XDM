// FIX-P2-03: Torrent settings mixin for SettingsProvider
import 'package:flutter/foundation.dart';

mixin TorrentSettingsMixin on ChangeNotifier {
  bool _globalTorrentSeeding = false;
  bool get globalTorrentSeeding => _globalTorrentSeeding;
  set globalTorrentSeeding(bool value) {
    if (_globalTorrentSeeding != value) {
      _globalTorrentSeeding = value;
      notifyListeners();
    }
  }

  bool _enableDht = true;
  bool get enableDht => _enableDht;
  set enableDht(bool value) {
    if (_enableDht != value) {
      _enableDht = value;
      notifyListeners();
    }
  }

  bool _enablePex = true;
  bool get enablePex => _enablePex;
  set enablePex(bool value) {
    if (_enablePex != value) {
      _enablePex = value;
      notifyListeners();
    }
  }

  bool _queueTorrents = true;
  bool get queueTorrents => _queueTorrents;
  set queueTorrents(bool value) {
    if (_queueTorrents != value) {
      _queueTorrents = value;
      notifyListeners();
    }
  }

  int _maxActiveTorrents = 5;
  int get maxActiveTorrents => _maxActiveTorrents;
  set maxActiveTorrents(int value) {
    if (_maxActiveTorrents != value) {
      _maxActiveTorrents = value;
      notifyListeners();
    }
  }
}
