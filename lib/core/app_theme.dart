import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Theme Colors (Dark Mode)
  static const Color background = Color(0xFF050508);
  static const Color surface = Color(0xFF0C0C12);
  static const Color cardBg = Color(0xFF121218);
  static const Color border = Color(0xFF1E1E28);

  // Theme Colors (Light Mode)
  static const Color lightBackground = Color(0xFFF4F6F9);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCardBg = Color(0xFFE9ECF4);
  static const Color lightBorder = Color(0xFFCBD5E1);

  // Glass-morphism Colors
  static const Color glassBg = Color(0x14FFFFFF); // ~8% white
  static const Color glassBorder = Color(0x1AFFFFFF); // ~10% white
  static const Color glassSurface = Color(0x0DFFFFFF); // ~5% white

  static const Color lightGlassBg = Color(0x0F000000); // ~6% black
  static const Color lightGlassBorder = Color(0x1F000000); // ~12% black

  // Neon Accents
  static const Color neonBlue = Color(0xFF00E5FF);
  static const Color neonViolet = Color(0xFF9D4EDD);
  static const Color neonGreen = Color(0xFF00FF87);
  static const Color neonRed = Color(0xFFFF0055);
  static const Color neonAmber = Color(0xFFFFB703);

  static const Color lightNeonBlue = Color(0xFF0097B2);
  static const Color lightNeonViolet = Color(0xFF7B2CBF);
  static const Color lightNeonGreen = Color(0xFF00A86B);
  static const Color lightNeonRed = Color(0xFFD90429);
  static const Color lightNeonAmber = Color(0xFFE5A900);

  // Text Colors
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF475569);

  static const Color lightTextPrimary = Color(0xFF0F172A);
  static const Color lightTextSecondary = Color(0xFF475569);
  static const Color lightTextMuted = Color(0xFF94A3B8);

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
    double glowOpacity = 0.08,
    bool isDark = true,
  }) {
    return BoxDecoration(
      color: accentColor.withValues(alpha: bgOpacity),
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: accentColor.withValues(alpha: borderOpacity),
        width: 0.8,
      ),
      boxShadow: [
        BoxShadow(
          color: accentColor.withValues(alpha: glowOpacity),
          blurRadius: 16.0,
          spreadRadius: 0,
        ),
      ],
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
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
      textTheme: TextTheme(
        displayLarge: GoogleFonts.spaceGrotesk(
          color: textPrimary,
          fontWeight: FontWeight.bold,
        ),
        displayMedium: GoogleFonts.spaceGrotesk(
          color: textPrimary,
          fontWeight: FontWeight.bold,
        ),
        displaySmall: GoogleFonts.spaceGrotesk(
          color: textPrimary,
          fontWeight: FontWeight.bold,
        ),
        headlineLarge: GoogleFonts.spaceGrotesk(
          color: textPrimary,
          fontWeight: FontWeight.bold,
          letterSpacing: -0.5,
        ),
        headlineMedium: GoogleFonts.spaceGrotesk(
          color: textPrimary,
          fontWeight: FontWeight.w600,
        ),
        headlineSmall: GoogleFonts.spaceGrotesk(
          color: textPrimary,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: GoogleFonts.spaceGrotesk(
          color: textPrimary,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: GoogleFonts.spaceGrotesk(
          color: textPrimary,
          fontWeight: FontWeight.w500,
        ),
        titleSmall: GoogleFonts.spaceGrotesk(
          color: textSecondary,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: GoogleFonts.inter(color: textPrimary),
        bodyMedium: GoogleFonts.inter(color: textSecondary),
        bodySmall: GoogleFonts.inter(color: textMuted),
        labelLarge: GoogleFonts.spaceGrotesk(
          color: neonBlue,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
        labelMedium: GoogleFonts.inter(
          color: textSecondary,
          fontWeight: FontWeight.w500,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: textPrimary),
      ),
      useMaterial3: true,
    );
  }

  static ThemeData get lightTheme {
    return ThemeData(
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
      textTheme: TextTheme(
        displayLarge: GoogleFonts.spaceGrotesk(
          color: lightTextPrimary,
          fontWeight: FontWeight.bold,
        ),
        displayMedium: GoogleFonts.spaceGrotesk(
          color: lightTextPrimary,
          fontWeight: FontWeight.bold,
        ),
        displaySmall: GoogleFonts.spaceGrotesk(
          color: lightTextPrimary,
          fontWeight: FontWeight.bold,
        ),
        headlineLarge: GoogleFonts.spaceGrotesk(
          color: lightTextPrimary,
          fontWeight: FontWeight.bold,
          letterSpacing: -0.5,
        ),
        headlineMedium: GoogleFonts.spaceGrotesk(
          color: lightTextPrimary,
          fontWeight: FontWeight.w600,
        ),
        headlineSmall: GoogleFonts.spaceGrotesk(
          color: lightTextPrimary,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: GoogleFonts.spaceGrotesk(
          color: lightTextPrimary,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: GoogleFonts.spaceGrotesk(
          color: lightTextPrimary,
          fontWeight: FontWeight.w500,
        ),
        titleSmall: GoogleFonts.spaceGrotesk(
          color: lightTextSecondary,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: GoogleFonts.inter(color: lightTextPrimary),
        bodyMedium: GoogleFonts.inter(color: lightTextSecondary),
        bodySmall: GoogleFonts.inter(color: lightTextMuted),
        labelLarge: GoogleFonts.spaceGrotesk(
          color: lightNeonBlue,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
        labelMedium: GoogleFonts.inter(
          color: lightTextSecondary,
          fontWeight: FontWeight.w500,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: lightTextPrimary),
      ),
      useMaterial3: true,
    );
  }
}
