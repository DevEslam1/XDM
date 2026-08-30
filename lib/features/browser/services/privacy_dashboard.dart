import 'package:flutter/foundation.dart';

class PrivacyDashboard extends ChangeNotifier {
  static final PrivacyDashboard instance = PrivacyDashboard._();
  PrivacyDashboard._();

  final Map<String, int> _blockedTrackers = {};
  final Map<String, int> _blockedAds = {};
  final Map<String, int> _blockedPopups = {};

  int get totalBlocked =>
      _blockedTrackers.values.fold<int>(0, (a, b) => a + b) +
      _blockedAds.values.fold<int>(0, (a, b) => a + b) +
      _blockedPopups.values.fold<int>(0, (a, b) => a + b);

  int get totalTrackers => _blockedTrackers.values.fold<int>(0, (a, b) => a + b);
  int get totalAds => _blockedAds.values.fold<int>(0, (a, b) => a + b);
  int get totalPopups => _blockedPopups.values.fold<int>(0, (a, b) => a + b);

  void recordBlocked(String type, String domain) {
    final cleanDomain = domain.toLowerCase().trim();
    if (cleanDomain.isEmpty) return;

    switch (type) {
      case 'tracker':
        _blockedTrackers[cleanDomain] = (_blockedTrackers[cleanDomain] ?? 0) + 1;
        break;
      case 'ad':
        _blockedAds[cleanDomain] = (_blockedAds[cleanDomain] ?? 0) + 1;
        break;
      case 'popup':
        _blockedPopups[cleanDomain] = (_blockedPopups[cleanDomain] ?? 0) + 1;
        break;
    }
    notifyListeners();
  }

  void reset() {
    _blockedTrackers.clear();
    _blockedAds.clear();
    _blockedPopups.clear();
    notifyListeners();
  }

  Map<String, dynamic> getStats() => {
        'totalBlocked': totalBlocked,
        'totalTrackers': totalTrackers,
        'totalAds': totalAds,
        'totalPopups': totalPopups,
        'trackers': Map<String, int>.unmodifiable(_blockedTrackers),
        'ads': Map<String, int>.unmodifiable(_blockedAds),
        'popups': Map<String, int>.unmodifiable(_blockedPopups),
      };
}
