import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Skips golden tests on Linux CI where font rendering may differ.
bool get skipGoldenTests => Platform.isLinux;

/// Standard golden test wrapper.
Future<void> expectGolden(
  WidgetTester tester,
  String goldenName, {
  bool skip = false,
}) async {
  if (skip || skipGoldenTests) return;
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$goldenName.png'),
  );
}
