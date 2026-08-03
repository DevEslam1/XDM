import '../goldens/golden_config.dart';

// FIX(16): Exporting from config to maintain backward compatibility with helper imports
export '../goldens/golden_config.dart' show shouldRunGoldenTests, expectGolden;

/// FIX(16): Getter kept for legacy test code, now backed by centralized config
bool get skipGoldenTests => !shouldRunGoldenTests;
