/// DMX Design Tokens — Single source of truth for all visual constants
abstract final class DmxTokens {
  // === SPACING SCALE (4px base) ===
  static const double space2xs = 2.0;
  static const double spaceXs = 4.0;
  static const double spaceSm = 8.0;
  static const double spaceMd = 12.0;
  static const double spaceLg = 16.0;
  static const double spaceXl = 20.0;
  static const double space2xl = 24.0;
  static const double space3xl = 32.0;
  static const double space4xl = 48.0;

  // === BORDER RADIUS SCALE ===
  static const double radiusSm = 8.0;
  static const double radiusMd = 12.0;
  static const double radiusLg = 16.0;
  static const double radiusXl = 20.0;
  static const double radius2xl = 24.0;
  static const double radiusFull = 9999.0;

  // === ICON SIZES ===
  static const double iconXs = 12.0;
  static const double iconSm = 16.0;
  static const double iconMd = 20.0;
  static const double iconLg = 24.0;
  static const double iconXl = 32.0;
  static const double iconDisplay = 48.0;

  // === FONT SIZES ===
  static const double textXs = 9.0;
  static const double textSm = 11.0;
  static const double textMd = 13.0;
  static const double textLg = 15.0;
  static const double textXl = 18.0;
  static const double textDisplay = 22.0;

  // === CARD DIMENSIONS ===
  static const double cardPadding = 14.0;
  static const double cardGap = 10.0;
  static const double cardMinHeight = 80.0;
  static const double cardMaxWidth = 600.0;

  // === ANIMATION DURATIONS ===
  static const Duration animFast = Duration(milliseconds: 150);
  static const Duration animNormal = Duration(milliseconds: 250);
  static const Duration animSlow = Duration(milliseconds: 400);
  static const Duration animReveal = Duration(milliseconds: 600);

  // === ELEVATION ===
  static const double elevationSm = 2.0;
  static const double elevationMd = 8.0;
  static const double elevationLg = 16.0;

  // === TOUCH TARGETS (minimum 48x48 for accessibility) ===
  static const double touchTargetMin = 48.0;

  // === BORDER WIDTHS ===
  static const double borderThin = 0.8;
  static const double borderMedium = 1.2;
  static const double borderThick = 2.0;

  // === PROGRESS BAR ===
  static const double progressHeightSm = 3.0;
  static const double progressHeightMd = 6.0;
  static const double progressHeightLg = 8.0;
}
