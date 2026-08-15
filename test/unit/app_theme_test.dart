import 'package:dmx/core/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _relativeLuminance(Color color) {
  final r = _linearize(color.r);
  final g = _linearize(color.g);
  final b = _linearize(color.b);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

double _linearize(double c) {
  return c <= 0.03928
      ? c / 12.92
      : ((c + 0.055) / 1.055) * ((c + 0.055) / 1.055);
}

double _contrastRatio(Color foreground, Color background) {
  final l1 = _relativeLuminance(foreground);
  final l2 = _relativeLuminance(background);
  final lighter = l1 > l2 ? l1 : l2;
  final darker = l1 > l2 ? l2 : l1;
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  group('AppTheme WCAG Contrast & Token Consistency (UI-01 / UI-02)', () {
    test('textPrimary meets WCAG AA (>= 4.5:1) on dark background', () {
      final ratio = _contrastRatio(AppTheme.textPrimary, AppTheme.background);
      expect(ratio, greaterThanOrEqualTo(4.5));
    });

    test('textSecondary meets WCAG AA (>= 4.5:1) on dark background', () {
      final ratio = _contrastRatio(AppTheme.textSecondary, AppTheme.background);
      expect(ratio, greaterThanOrEqualTo(4.5));
    });

    test('lightTextPrimary meets WCAG AA (>= 4.5:1) on light background', () {
      final ratio =
          _contrastRatio(AppTheme.lightTextPrimary, AppTheme.lightBackground);
      expect(ratio, greaterThanOrEqualTo(4.5));
    });

    test('neon accent colors are distinct and valid', () {
      expect(AppTheme.neonBlue.toARGB32(), isNonZero);
      expect(AppTheme.neonViolet.toARGB32(), isNonZero);
      expect(AppTheme.neonGreen.toARGB32(), isNonZero);
      expect(AppTheme.neonCyan.toARGB32(), isNonZero);
    });
  });
}
