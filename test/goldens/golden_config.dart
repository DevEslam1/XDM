import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// FIX(16): Determines whether golden tests should run on this platform.
/// Golden tests are enabled on macOS and Windows (stable font rendering).
/// On Linux, they are enabled only when the GOLDEN_TESTS env var is set
/// (CI can set this when running with a known font set).
bool get shouldRunGoldenTests {
  if (kIsWeb) return false;
  if (Platform.isMacOS || Platform.isWindows) return true;
  if (Platform.isLinux) {
    return Platform.environment['GOLDEN_TESTS'] == 'true';
  }
  return false; // Fuchsia, etc.
}

/// FIX(16): Standard golden test wrapper that handles platform skips.
Future<void> expectGolden(
  WidgetTester tester,
  String goldenName, {
  bool? skip,
}) async {
  final effectiveSkip = skip ?? !shouldRunGoldenTests;
  if (effectiveSkip) return;

  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$goldenName.png'),
  );
}
