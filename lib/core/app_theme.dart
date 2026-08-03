import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// XDM design system — "Signal Deck" (refined)
/// Display: Space Grotesk · Body: Inter
class AppTheme {
  AppTheme._();

  // ── Surfaces (dark) ──
  static const Color background = Color(0xFF0F1117);
  static const Color bgSunken = Color(0xFF0B0D12);
  static const Color surface = Color(0xFF161A22);
  static const Color surfaceRaised = Color(0xFF1B202B);
  static const Color cardBg = Color(0xFF1B202B);
  static const Color overlayScrim = Color(0xB3070910);

  // ── Surfaces (light) ──
  static const Color lightBackground = Color(0xFFF3F5F9);
  static const Color lightBgSunken = Color(0xFFE9EDF4);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceRaised = Color(0xFFFBFCFE);
  static const Color lightCardBg = Color(0xFFFBFCFE);
  static const Color lightOverlayScrim = Color(0x66101828);

  // ── Borders ──
  static const Color border = Color(0xFF2A3040);
  static const Color borderStrong = Color(0xFF3A4154);
  static const Color borderSubtle = Color(0xFF1E2330);
  static const Color lightBorder = Color(0xFFD4DAE5);
  static const Color lightBorderStrong = Color(0xFFB9C1D0);
  static const Color lightBorderSubtle = Color(0xFFE4E8F0);

  // ── Glass (legacy) ──
  static const Color glassBg = Color(0x0FFFFFFF);
  static const Color glassBorder = Color(0x16FFFFFF);
  static const Color glassSurface = Color(0x0AFFFFFF);
  static const Color lightGlassBg = Color(0x0A000000);
  static const Color lightGlassBorder = Color(0x14000000);

  // ── Accents ──
  static const Color neonBlue = Color(0xFF3B82F6);
  static const Color neonViolet = Color(0xFF8B5CF6);
  static const Color neonGreen = Color(0xFF10B981);
  static const Color neonRed = Color(0xFFEF4444);
  static const Color neonAmber = Color(0xFFF59E0B);
  static const Color neonYellow = Color(0xFFFACC15);
  static const Color neonCyan = Color(0xFF22D3EE);
  static const Color lightNeonBlue = Color(0xFF1D63D8);
  static const Color lightNeonViolet = Color(0xFF6D3AC4);
  static const Color lightNeonGreen = Color(0xFF047857);
  static const Color lightNeonRed = Color(0xFFC21F1F);
  static const Color lightNeonAmber = Color(0xFFB45309);
  static const Color lightNeonYellow = Color(0xFFA16207);
  static const Color lightNeonCyan = Color(0xFF0E7490);

  // ── Text ──
  static const Color textPrimary = Color(0xFFF2F4F8);
  static const Color textSecondary = Color(0xFF9AA3B5);
  static const Color textMuted = Color(0xFF5F6B82);
  static const Color lightTextPrimary = Color(0xFF101828);
  static const Color lightTextSecondary = Color(0xFF475467);
  static const Color lightTextMuted = Color(0xFF8A94A6);

  // ── Accessibility: focus & contrast ──
  /// High-visibility focus ring (keyboard / screen-reader focus).
  static const Color focusRing = Color(0xFF60A5FA);
  static const Color lightFocusRing = Color(0xFF1D4ED8);

  /// 3:1+ contrast fill used behind a focused widget in high-contrast mode.
  static const Color focusFill = Color(0x33008FE0);
  static const Color lightFocusFill = Color(0x33008FE0);

  static const String fontDisplay = 'Space Grotesk';
  static const String fontBody = 'Inter';

  // ══════════════════════════════════════════════════════════════
  //  MOTION TOKENS — shared timing so the whole app moves as one
  // ══════════════════════════════════════════════════════════════
  static const Duration motionFast = Duration(milliseconds: 140);
  static const Duration motionBase = Duration(milliseconds: 240);
  static const Duration motionSlow = Duration(milliseconds: 420);
  static const Duration motionReveal = Duration(milliseconds: 600);
  static const Curve motionCurve = Curves.easeOutCubic;
  static const Curve motionSpring = Curves.easeOutQuart;

  static Color inkOn(Color accent) =>
      accent.computeLuminance() > 0.45 ? const Color(0xFF101318) : Colors.white;

  static Color resolve(bool isDark, Color dark, Color light) =>
      isDark ? dark : light;

  /// Primary channel accent for the current mode.
  static Color accent(bool isDark) => isDark ? neonBlue : lightNeonBlue;

  static TextStyle dataStyle({
    required bool isDark,
    double size = 12,
    FontWeight weight = FontWeight.w700,
    Color? color,
  }) {
    return TextStyle(
      fontFamily: fontDisplay,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: 0.4,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: color ?? (isDark ? textPrimary : lightTextPrimary),
    );
  }

  static TextStyle microLabel({
    required bool isDark,
    Color? color,
    double size = 10,
  }) {
    return TextStyle(
      fontFamily: fontDisplay,
      fontSize: size,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.4,
      color: color ?? (isDark ? textMuted : lightTextMuted),
    );
  }

  // ── Pre-allocated type scales ──
  static const TextStyle _dDisplayLarge = TextStyle(
    fontFamily: fontDisplay,
    color: textPrimary,
    fontWeight: FontWeight.w700,
    fontSize: 34,
    letterSpacing: -0.6,
  );
  static const TextStyle _dDisplayMedium = TextStyle(
    fontFamily: fontDisplay,
    color: textPrimary,
    fontWeight: FontWeight.w700,
    fontSize: 28,
    letterSpacing: -0.4,
  );
  static const TextStyle _dDisplaySmall = TextStyle(
    fontFamily: fontDisplay,
    color: textPrimary,
    fontWeight: FontWeight.w700,
    fontSize: 22,
    letterSpacing: -0.2,
  );
  static const TextStyle _dHeadlineLarge = TextStyle(
    fontFamily: fontDisplay,
    color: textPrimary,
    fontWeight: FontWeight.w700,
    fontSize: 20,
  );
  static const TextStyle _dHeadlineMedium = TextStyle(
    fontFamily: fontDisplay,
    color: textPrimary,
    fontWeight: FontWeight.w600,
    fontSize: 17,
  );
  static const TextStyle _dHeadlineSmall = TextStyle(
    fontFamily: fontDisplay,
    color: textPrimary,
    fontWeight: FontWeight.w600,
    fontSize: 15,
  );
  static const TextStyle _dTitleLarge = TextStyle(
    fontFamily: fontDisplay,
    color: textPrimary,
    fontWeight: FontWeight.w600,
    fontSize: 14,
  );
  static const TextStyle _dTitleMedium = TextStyle(
    fontFamily: fontDisplay,
    color: textPrimary,
    fontWeight: FontWeight.w600,
    fontSize: 13,
  );
  static const TextStyle _dTitleSmall = TextStyle(
    fontFamily: fontDisplay,
    color: textSecondary,
    fontWeight: FontWeight.w600,
    fontSize: 12,
  );
  static const TextStyle _dBodyLarge = TextStyle(
    fontFamily: fontBody,
    color: textPrimary,
    fontSize: 14,
    height: 1.45,
  );
  static const TextStyle _dBodyMedium = TextStyle(
    fontFamily: fontBody,
    color: textSecondary,
    fontSize: 12.5,
    height: 1.45,
  );
  static const TextStyle _dBodySmall = TextStyle(
    fontFamily: fontBody,
    color: textMuted,
    fontSize: 11,
    height: 1.4,
  );
  static const TextStyle _dLabelLarge = TextStyle(
    fontFamily: fontDisplay,
    color: neonBlue,
    fontWeight: FontWeight.w700,
    fontSize: 11,
    letterSpacing: 1.2,
  );
  static const TextStyle _dLabelMedium = TextStyle(
    fontFamily: fontDisplay,
    color: textSecondary,
    fontWeight: FontWeight.w600,
    fontSize: 10,
    letterSpacing: 0.8,
  );
  static const TextStyle _dLabelSmall = TextStyle(
    fontFamily: fontDisplay,
    color: textMuted,
    fontWeight: FontWeight.w600,
    fontSize: 9,
    letterSpacing: 0.6,
  );

  static const TextStyle _lDisplayLarge = TextStyle(
    fontFamily: fontDisplay,
    color: lightTextPrimary,
    fontWeight: FontWeight.w700,
    fontSize: 34,
    letterSpacing: -0.6,
  );
  static const TextStyle _lDisplayMedium = TextStyle(
    fontFamily: fontDisplay,
    color: lightTextPrimary,
    fontWeight: FontWeight.w700,
    fontSize: 28,
    letterSpacing: -0.4,
  );
  static const TextStyle _lDisplaySmall = TextStyle(
    fontFamily: fontDisplay,
    color: lightTextPrimary,
    fontWeight: FontWeight.w700,
    fontSize: 22,
    letterSpacing: -0.2,
  );
  static const TextStyle _lHeadlineLarge = TextStyle(
    fontFamily: fontDisplay,
    color: lightTextPrimary,
    fontWeight: FontWeight.w700,
    fontSize: 20,
  );
  static const TextStyle _lHeadlineMedium = TextStyle(
    fontFamily: fontDisplay,
    color: lightTextPrimary,
    fontWeight: FontWeight.w600,
    fontSize: 17,
  );
  static const TextStyle _lHeadlineSmall = TextStyle(
    fontFamily: fontDisplay,
    color: lightTextPrimary,
    fontWeight: FontWeight.w600,
    fontSize: 15,
  );
  static const TextStyle _lTitleLarge = TextStyle(
    fontFamily: fontDisplay,
    color: lightTextPrimary,
    fontWeight: FontWeight.w600,
    fontSize: 14,
  );
  static const TextStyle _lTitleMedium = TextStyle(
    fontFamily: fontDisplay,
    color: lightTextPrimary,
    fontWeight: FontWeight.w600,
    fontSize: 13,
  );
  static const TextStyle _lTitleSmall = TextStyle(
    fontFamily: fontDisplay,
    color: lightTextSecondary,
    fontWeight: FontWeight.w600,
    fontSize: 12,
  );
  static const TextStyle _lBodyLarge = TextStyle(
    fontFamily: fontBody,
    color: lightTextPrimary,
    fontSize: 14,
    height: 1.45,
  );
  static const TextStyle _lBodyMedium = TextStyle(
    fontFamily: fontBody,
    color: lightTextSecondary,
    fontSize: 12.5,
    height: 1.45,
  );
  static const TextStyle _lBodySmall = TextStyle(
    fontFamily: fontBody,
    color: lightTextMuted,
    fontSize: 11,
    height: 1.4,
  );
  static const TextStyle _lLabelLarge = TextStyle(
    fontFamily: fontDisplay,
    color: lightNeonBlue,
    fontWeight: FontWeight.w700,
    fontSize: 11,
    letterSpacing: 1.2,
  );
  static const TextStyle _lLabelMedium = TextStyle(
    fontFamily: fontDisplay,
    color: lightTextSecondary,
    fontWeight: FontWeight.w600,
    fontSize: 10,
    letterSpacing: 0.8,
  );
  static const TextStyle _lLabelSmall = TextStyle(
    fontFamily: fontDisplay,
    color: lightTextMuted,
    fontWeight: FontWeight.w600,
    fontSize: 9,
    letterSpacing: 0.6,
  );

  // ── Decoration helpers ──
  static BoxDecoration panel({
    required bool isDark,
    double radius = 16,
    Color? accentColor,
    double accentAlpha = 0.28,
    bool elevated = false,
  }) {
    final borderClr = accentColor != null
        ? accentColor.withValues(alpha: accentAlpha)
        : (isDark ? border : lightBorder);
    return BoxDecoration(
      color: isDark
          ? (elevated ? surfaceRaised : surface)
          : (elevated ? lightSurfaceRaised : lightSurface),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: borderClr,
        width: accentColor != null ? 1 : 0.8,
      ),
      boxShadow: elevated
          ? [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ]
          : null,
    );
  }

  static BoxDecoration well({required bool isDark, double radius = 12}) {
    return BoxDecoration(
      color: isDark ? bgSunken : lightBgSunken,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: isDark ? borderSubtle : lightBorderSubtle,
        width: 0.8,
      ),
    );
  }

  static ShapeBorder cockpitShape({
    double radius = 14,
    double notch = 14,
    BorderSide side = const BorderSide(color: border, width: 0.8),
  }) {
    return CockpitNotchBorder(radius: radius, notch: notch, side: side);
  }

  static BoxShadow glow(
    Color color, {
    double alpha = 0.28,
    double blur = 16,
    double spread = -2,
  }) {
    return BoxShadow(
      color: color.withValues(alpha: alpha),
      blurRadius: blur,
      spreadRadius: spread,
    );
  }

  /// Returns a vertical gradient for progress fills with a subtle glow effect.
  static LinearGradient glowGradient(Color base, {bool reverse = false}) {
    return LinearGradient(
      begin: reverse ? Alignment.bottomCenter : Alignment.topCenter,
      end: reverse ? Alignment.topCenter : Alignment.bottomCenter,
      colors: [
        base.withValues(alpha: 0.7),
        base,
        base.withValues(alpha: 0.9),
      ],
      stops: const [0.0, 0.5, 1.0],
    );
  }

  /// DRY helper for consistent chip/pill decoration.
  static BoxDecoration chipDecoration({
    required Color color,
    required bool isDark,
    double radius = 8,
    double borderAlpha = 0.25,
    double fillAlpha = 0.10,
  }) {
    return BoxDecoration(
      color: color.withValues(alpha: fillAlpha),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: color.withValues(alpha: borderAlpha),
        width: 0.8,
      ),
    );
  }

  static BoxDecoration progressTrack({
    required bool isDark,
    double radius = 4,
  }) {
    return BoxDecoration(
      color: isDark ? borderSubtle : lightBorderSubtle,
      borderRadius: BorderRadius.circular(radius),
    );
  }

  static BoxDecoration progressFill(Color color, {double radius = 4}) {
    return BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: [glow(color, alpha: 0.35, blur: 6, spread: 0)],
    );
  }

  // Legacy glass helpers
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
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark ? 0.20 : 0.06),
          blurRadius: 8.0,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  static SystemUiOverlayStyle statusBar(bool isDark) {
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: isDark ? background : lightBackground,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
    );
  }

  // ── Themes ──
  static ThemeData? _cachedDarkTheme;
  static ThemeData get darkTheme =>
      _cachedDarkTheme ??= _buildTheme(isDark: true);
  static ThemeData? _cachedLightTheme;
  static ThemeData get lightTheme =>
      _cachedLightTheme ??= _buildTheme(isDark: false);

  static ThemeData _buildTheme({required bool isDark}) {
    final bg = isDark ? background : lightBackground;
    final surf = isDark ? surface : lightSurface;
    final card = isDark ? cardBg : lightCardBg;
    final bdr = isDark ? border : lightBorder;
    final primary = isDark ? neonBlue : lightNeonBlue;
    final secondary = isDark ? neonViolet : lightNeonViolet;
    final error = isDark ? neonRed : lightNeonRed;
    final muted = isDark ? textMuted : lightTextMuted;

    return ThemeData(
      useMaterial3: true,
      brightness: isDark ? Brightness.dark : Brightness.light,
      scaffoldBackgroundColor: bg,
      primaryColor: primary,
      colorScheme: ColorScheme(
        brightness: isDark ? Brightness.dark : Brightness.light,
        primary: primary,
        onPrimary: inkOn(primary),
        secondary: secondary,
        onSecondary: inkOn(secondary),
        surface: surf,
        onSurface: isDark ? textPrimary : lightTextPrimary,
        error: error,
        onError: Colors.white,
        outline: bdr,
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: bdr, width: 0.8),
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surf,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: isDark ? borderStrong : lightBorderStrong,
            width: 0.8,
          ),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? bgSunken : lightBgSunken,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isDark ? borderSubtle : lightBorderSubtle,
            width: 0.8,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isDark ? borderSubtle : lightBorderSubtle,
            width: 0.8,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: primary.withValues(alpha: 0.6),
            width: 1.4,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: error.withValues(alpha: 0.6),
            width: 1.2,
          ),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: error.withValues(alpha: 0.8),
            width: 1.4,
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surf,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: isDark ? borderStrong : lightBorderStrong,
            width: 0.6,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return primary;
          return isDark ? textSecondary : lightTextSecondary;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primary.withValues(alpha: 0.22);
          }
          return isDark ? borderSubtle : lightBorderSubtle;
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: primary,
        inactiveTrackColor: isDark ? borderSubtle : lightBorderSubtle,
        thumbColor: primary,
        overlayColor: primary.withValues(alpha: 0.14),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: isDark ? surfaceRaised : lightSurfaceRaised,
        side: BorderSide(color: bdr, width: 0.8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        labelStyle: TextStyle(
          fontFamily: fontDisplay,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: isDark ? textSecondary : lightTextSecondary,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? surfaceRaised : const Color(0xFF101828),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isDark ? borderStrong : Colors.transparent,
            width: 0.6,
          ),
        ),
        textStyle: TextStyle(
          fontFamily: fontBody,
          fontSize: 11,
          color: isDark ? textPrimary : Colors.white,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(4),
        radius: const Radius.circular(4),
        thumbColor: WidgetStateProperty.all(
          (isDark ? neonBlue : lightNeonBlue).withValues(alpha: 0.35),
        ),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        titleTextStyle: TextStyle(
          fontFamily: fontBody,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: isDark ? textPrimary : lightTextPrimary,
        ),
        subtitleTextStyle: TextStyle(
          fontFamily: fontBody,
          fontSize: 11,
          color: muted,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: isDark ? borderSubtle : lightBorderSubtle,
        thickness: 0.8,
        space: 1,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      textTheme: TextTheme(
        displayLarge: isDark ? _dDisplayLarge : _lDisplayLarge,
        displayMedium: isDark ? _dDisplayMedium : _lDisplayMedium,
        displaySmall: isDark ? _dDisplaySmall : _lDisplaySmall,
        headlineLarge: isDark ? _dHeadlineLarge : _lHeadlineLarge,
        headlineMedium: isDark ? _dHeadlineMedium : _lHeadlineMedium,
        headlineSmall: isDark ? _dHeadlineSmall : _lHeadlineSmall,
        titleLarge: isDark ? _dTitleLarge : _lTitleLarge,
        titleMedium: isDark ? _dTitleMedium : _lTitleMedium,
        titleSmall: isDark ? _dTitleSmall : _lTitleSmall,
        bodyLarge: isDark ? _dBodyLarge : _lBodyLarge,
        bodyMedium: isDark ? _dBodyMedium : _lBodyMedium,
        bodySmall: isDark ? _dBodySmall : _lBodySmall,
        labelLarge: isDark ? _dLabelLarge : _lLabelLarge,
        labelMedium: isDark ? _dLabelMedium : _lLabelMedium,
        labelSmall: isDark ? _dLabelSmall : _lLabelSmall,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(
          color: isDark ? textPrimary : lightTextPrimary,
        ),
        systemOverlayStyle: statusBar(isDark),
      ),
    );
  }
}

class CockpitNotchBorder extends ShapeBorder {
  final double radius;
  final double notch;
  final BorderSide side;
  const CockpitNotchBorder({
    this.radius = 14,
    this.notch = 14,
    this.side = const BorderSide(color: AppTheme.border, width: 0.8),
  });

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  ShapeBorder scale(double t) => CockpitNotchBorder(
        radius: radius * t,
        notch: notch * t,
        side: side.scale(t),
      );

  Path _path(Rect r) {
    final rad = math.min(radius, math.min(r.width, r.height) / 2);
    final n = math.min(notch, math.min(r.width, r.height) / 2);
    final path = Path();
    path.moveTo(r.left, r.top + rad);
    path.arcTo(
      Rect.fromLTWH(r.left, r.top, rad * 2, rad * 2),
      math.pi,
      math.pi / 2,
      false,
    );
    path.lineTo(r.right - n, r.top);
    path.lineTo(r.right, r.top + n);
    path.lineTo(r.right, r.bottom - rad);
    path.arcTo(
      Rect.fromLTWH(r.right - rad * 2, r.bottom - rad * 2, rad * 2, rad * 2),
      0,
      math.pi / 2,
      false,
    );
    path.lineTo(r.left + rad, r.bottom);
    path.arcTo(
      Rect.fromLTWH(r.left, r.bottom - rad * 2, rad * 2, rad * 2),
      math.pi / 2,
      math.pi / 2,
      false,
    );
    path.close();
    return path;
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _path(rect.deflate(side.width));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _path(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) {
      return;
    }
    canvas.drawPath(
      _path(rect),
      Paint()
        ..color = side.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = side.width,
    );
  }
}
