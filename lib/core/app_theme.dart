import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTheme {
  // Theme Colors (Dark Mode)
  static const Color background = Color(0xFF121212);
  static const Color surface = Color(0xFF1E1E1E);
  static const Color cardBg = Color(0xFF242424);
  static const Color border = Color(0xFF333333);

  // Theme Colors (Light Mode)
  static const Color lightBackground = Color(0xFFF4F6F9);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCardBg = Color(0xFFE9ECF4);
  static const Color lightBorder = Color(0xFFCBD5E1);

  // Glass-morphism Colors
  static const Color glassBg = Color(0x14FFFFFF);
  static const Color glassBorder = Color(0x1AFFFFFF);
  static const Color glassSurface = Color(0x0DFFFFFF);

  static const Color lightGlassBg = Color(0x0F000000);
  static const Color lightGlassBorder = Color(0x1F000000);

  // Professional Accents
  static const Color neonBlue = Color(0xFF3B82F6);
  static const Color neonViolet = Color(0xFF8B5CF6);
  static const Color neonGreen = Color(0xFF10B981);
  static const Color neonRed = Color(0xFFEF4444);
  static const Color neonAmber = Color(0xFFF59E0B);

  static const Color lightNeonBlue = Color(0xFF0097B2);
  static const Color lightNeonViolet = Color(0xFF7B2CBF);
  static const Color lightNeonGreen = Color(0xFF00A86B);
  static const Color lightNeonRed = Color(0xFFD90429);
  static const Color lightNeonAmber = Color(0xFFE5A900);

  static const Color neonYellow = Color(0xFFFACC15);
  static const Color lightNeonYellow = Color(0xFFD97706);

  // Text Colors
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF475569);

  static const Color lightTextPrimary = Color(0xFF0F172A);
  static const Color lightTextSecondary = Color(0xFF475569);
  static const Color lightTextMuted = Color(0xFF94A3B8);

  // Pre-allocated TextStyles for dark theme (reused across builds)
  static const TextStyle _darkDisplayLarge = TextStyle(fontFamily: 'Space Grotesk', color: textPrimary, fontWeight: FontWeight.bold);
  static const TextStyle _darkDisplayMedium = TextStyle(fontFamily: 'Space Grotesk', color: textPrimary, fontWeight: FontWeight.bold);
  static const TextStyle _darkDisplaySmall = TextStyle(fontFamily: 'Space Grotesk', color: textPrimary, fontWeight: FontWeight.bold);
  static const TextStyle _darkHeadlineLarge = TextStyle(fontFamily: 'Space Grotesk', color: textPrimary, fontWeight: FontWeight.bold);
  static const TextStyle _darkHeadlineMedium = TextStyle(fontFamily: 'Space Grotesk', color: textPrimary, fontWeight: FontWeight.w600);
  static const TextStyle _darkHeadlineSmall = TextStyle(fontFamily: 'Space Grotesk', color: textPrimary, fontWeight: FontWeight.w600);
  static const TextStyle _darkTitleLarge = TextStyle(fontFamily: 'Space Grotesk', color: textPrimary, fontWeight: FontWeight.w600);
  static const TextStyle _darkTitleMedium = TextStyle(fontFamily: 'Space Grotesk', color: textPrimary, fontWeight: FontWeight.w500);
  static const TextStyle _darkTitleSmall = TextStyle(fontFamily: 'Space Grotesk', color: textSecondary, fontWeight: FontWeight.w500);
  static const TextStyle _darkBodyLarge = TextStyle(fontFamily: 'Inter', color: textPrimary);
  static const TextStyle _darkBodyMedium = TextStyle(fontFamily: 'Inter', color: textSecondary);
  static const TextStyle _darkBodySmall = TextStyle(fontFamily: 'Inter', color: textMuted);
  static const TextStyle _darkLabelLarge = TextStyle(fontFamily: 'Space Grotesk', color: neonBlue, fontWeight: FontWeight.w600);
  static const TextStyle _darkLabelMedium = TextStyle(fontFamily: 'Inter', color: textSecondary, fontWeight: FontWeight.w500);

  // Pre-allocated TextStyles for light theme
  static const TextStyle _lightDisplayLarge = TextStyle(fontFamily: 'Space Grotesk', color: lightTextPrimary, fontWeight: FontWeight.bold);
  static const TextStyle _lightDisplayMedium = TextStyle(fontFamily: 'Space Grotesk', color: lightTextPrimary, fontWeight: FontWeight.bold);
  static const TextStyle _lightDisplaySmall = TextStyle(fontFamily: 'Space Grotesk', color: lightTextPrimary, fontWeight: FontWeight.bold);
  static const TextStyle _lightHeadlineLarge = TextStyle(fontFamily: 'Space Grotesk', color: lightTextPrimary, fontWeight: FontWeight.bold);
  static const TextStyle _lightHeadlineMedium = TextStyle(fontFamily: 'Space Grotesk', color: lightTextPrimary, fontWeight: FontWeight.w600);
  static const TextStyle _lightHeadlineSmall = TextStyle(fontFamily: 'Space Grotesk', color: lightTextPrimary, fontWeight: FontWeight.w600);
  static const TextStyle _lightTitleLarge = TextStyle(fontFamily: 'Space Grotesk', color: lightTextPrimary, fontWeight: FontWeight.w600);
  static const TextStyle _lightTitleMedium = TextStyle(fontFamily: 'Space Grotesk', color: lightTextPrimary, fontWeight: FontWeight.w500);
  static const TextStyle _lightTitleSmall = TextStyle(fontFamily: 'Space Grotesk', color: lightTextSecondary, fontWeight: FontWeight.w500);
  static const TextStyle _lightBodyLarge = TextStyle(fontFamily: 'Inter', color: lightTextPrimary);
  static const TextStyle _lightBodyMedium = TextStyle(fontFamily: 'Inter', color: lightTextSecondary);
  static const TextStyle _lightBodySmall = TextStyle(fontFamily: 'Inter', color: lightTextMuted);
  static const TextStyle _lightLabelLarge = TextStyle(fontFamily: 'Space Grotesk', color: lightNeonBlue, fontWeight: FontWeight.w600);
  static const TextStyle _lightLabelMedium = TextStyle(fontFamily: 'Inter', color: lightTextSecondary, fontWeight: FontWeight.w500);

  // --- Glass decoration helpers ---

  /// Standard glass panel decoration (cards, panels, sections)
  static BoxDecoration glassDecoration({
    double borderRadius = 24.0,
    Color? tintColor,
    double tintOpacity = 0.06,
    bool isDark = true,
  }) {
    return BoxDecoration(
      color: tintColor != null
          ? tintColor.withValues(alpha: tintOpacity)
          : (isDark ? glassBg : lightGlassBg),
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: isDark ? glassBorder : lightGlassBorder,
        width: 0.8,
      ),
    );
  }

  /// Accent-tinted glass decoration with subtle glow
  static BoxDecoration glassAccentDecoration({
    required Color accentColor,
    double borderRadius = 24.0,
    double bgOpacity = 0.08,
    double borderOpacity = 0.2,
    bool isDark = true,
  }) {
    return BoxDecoration(
      color: accentColor.withValues(alpha: bgOpacity),
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: accentColor.withValues(alpha: borderOpacity),
        width: 0.8,
      ),
      boxShadow: const [
        BoxShadow(
          color: Colors.black12,
          blurRadius: 8.0,
          spreadRadius: 0,
          offset: Offset(0, 2),
        ),
      ],
    );
  }

  static ThemeData? _cachedDarkTheme;
  static ThemeData get darkTheme {
    return _cachedDarkTheme ??= ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      primaryColor: neonBlue,
      colorScheme: const ColorScheme.dark(
        primary: neonBlue,
        secondary: neonViolet,
        surface: surface,
        error: neonRed,
      ),
      cardTheme: CardThemeData(
        color: glassBg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: glassBorder, width: 0.8),
          borderRadius: const BorderRadius.all(Radius.circular(24)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface.withValues(alpha: 0.92),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: glassBorder, width: 0.8),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF0F0F16),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: Color(0x15FFFFFF), width: 0.8),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: Color(0x15FFFFFF), width: 0.8),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: neonBlue.withValues(alpha: 0.5), width: 1.2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: neonRed.withValues(alpha: 0.5), width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: neonRed.withValues(alpha: 0.5), width: 1.2),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface.withValues(alpha: 0.92),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: glassBorder, width: 0.6),
        ),
      ),
      textTheme: const TextTheme(
        displayLarge: _darkDisplayLarge,
        displayMedium: _darkDisplayMedium,
        displaySmall: _darkDisplaySmall,
        headlineLarge: _darkHeadlineLarge,
        headlineMedium: _darkHeadlineMedium,
        headlineSmall: _darkHeadlineSmall,
        titleLarge: _darkTitleLarge,
        titleMedium: _darkTitleMedium,
        titleSmall: _darkTitleSmall,
        bodyLarge: _darkBodyLarge,
        bodyMedium: _darkBodyMedium,
        bodySmall: _darkBodySmall,
        labelLarge: _darkLabelLarge,
        labelMedium: _darkLabelMedium,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: textPrimary),
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
      ),
    );
  }

  static ThemeData? _cachedLightTheme;
  static ThemeData get lightTheme {
    return _cachedLightTheme ??= ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: lightBackground,
      primaryColor: lightNeonBlue,
      colorScheme: const ColorScheme.light(
        primary: lightNeonBlue,
        secondary: lightNeonViolet,
        surface: lightSurface,
        error: lightNeonRed,
      ),
      cardTheme: CardThemeData(
        color: lightGlassBg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: lightGlassBorder, width: 0.8),
          borderRadius: const BorderRadius.all(Radius.circular(24)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: lightSurface.withValues(alpha: 0.95),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: lightGlassBorder, width: 0.8),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF1F5F9),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: Color(0x0D000000), width: 0.8),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: Color(0x0D000000), width: 0.8),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: lightNeonBlue.withValues(alpha: 0.5), width: 1.2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: lightNeonRed.withValues(alpha: 0.5), width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: lightNeonRed.withValues(alpha: 0.5), width: 1.2),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: lightSurface.withValues(alpha: 0.95),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: lightGlassBorder, width: 0.6),
        ),
      ),
      textTheme: const TextTheme(
        displayLarge: _lightDisplayLarge,
        displayMedium: _lightDisplayMedium,
        displaySmall: _lightDisplaySmall,
        headlineLarge: _lightHeadlineLarge,
        headlineMedium: _lightHeadlineMedium,
        headlineSmall: _lightHeadlineSmall,
        titleLarge: _lightTitleLarge,
        titleMedium: _lightTitleMedium,
        titleSmall: _lightTitleSmall,
        bodyLarge: _lightBodyLarge,
        bodyMedium: _lightBodyMedium,
        bodySmall: _lightBodySmall,
        labelLarge: _lightLabelLarge,
        labelMedium: _lightLabelMedium,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: lightTextPrimary),
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
        ),
      ),
    );
  }
}
