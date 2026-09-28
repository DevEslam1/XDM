import 'dart:math';

import 'package:flutter/material.dart';

enum ScreenType { phone, tablet, desktop }

ScreenType getScreenType(BuildContext context) {
  final w = MediaQuery.of(context).size.width;
  if (w >= 900) return ScreenType.desktop;
  if (w >= 600) return ScreenType.tablet;
  return ScreenType.phone;
}

bool isTablet(BuildContext context) =>
    getScreenType(context) != ScreenType.phone;
bool isPhone(BuildContext context) =>
    getScreenType(context) == ScreenType.phone;
bool isDesktop(BuildContext context) =>
    getScreenType(context) == ScreenType.desktop;

class ResponsiveBuilder extends StatelessWidget {
  final Widget Function(BuildContext, ScreenType) builder;
  const ResponsiveBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final type = constraints.maxWidth >= 900
            ? ScreenType.desktop
            : constraints.maxWidth >= 600
                ? ScreenType.tablet
                : ScreenType.phone;
        return builder(context, type);
      },
    );
  }
}

double contentMaxWidth(BuildContext context) {
  final type = getScreenType(context);
  if (type == ScreenType.desktop) return 1200;
  if (type == ScreenType.tablet) return 900;
  return double.infinity;
}

EdgeInsets screenPadding(BuildContext context) {
  final type = getScreenType(context);
  final h = type == ScreenType.phone ? 20.0 : 32.0;
  final v = type == ScreenType.phone ? 8.0 : 16.0;
  return EdgeInsets.symmetric(horizontal: h, vertical: v);
}

const double kGridTileHeight = 140.0;
const double kGridTileGap = 24.0;

double gridChildAspectRatio(BuildContext context,
    {int columns = 2, double horizontalPadding = 32.0}) {
  final w = MediaQuery.sizeOf(context).width;
  final effectiveColumns = max(1, columns);
  final effectivePadding = w < 320 ? 8.0 : horizontalPadding;
  final availableWidth = max(40.0, w - effectivePadding * 2);
  // There are (columns - 1) gaps between `columns` tiles in a row, not one
  // gap per tile — subtracting a full gap per column (the previous formula)
  // made every tile narrower than intended, increasingly so as columns grew.
  final tileWidth =
      (availableWidth - kGridTileGap * (effectiveColumns - 1)) / effectiveColumns;
  final safeTileWidth = tileWidth <= 0 ? availableWidth : tileWidth;
  final ratio = safeTileWidth / kGridTileHeight;
  return ratio.clamp(0.3, 3.0);
}

bool isLandscape(BuildContext context) =>
    MediaQuery.orientationOf(context) == Orientation.landscape;

bool isPhoneLandscape(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width > size.height && size.height < 600;
}

bool isTabletLandscape(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width > size.height && size.height >= 600 && size.width >= 600;
}

bool shouldShowSideNavigation(BuildContext context) {
  final type = getScreenType(context);
  return type == ScreenType.desktop || isLandscape(context);
}

/// Determines whether task cards should be displayed in a multi-column grid
/// vs a single unified list.
/// Only activates for wide screens (desktop, large landscape, or tablets >= 850px)
/// so portrait tablets maintain a clean, uncrowded single-column list.
bool isMultiColumnLayout(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final isLand = size.width > size.height;
  if (size.width >= 850) return true;
  if (isTabletLandscape(context)) return true;
  if (isLand && size.width >= 640) return true;
  return false;
}

/// Determines whether the download details view should split into a two-pane layout.
/// Portrait tablets (width < 900) should use a single centered column so telemetry,
/// speed, and stats never truncate or wrap awkwardly.
bool shouldShowTwoPaneDetails(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final isLand = size.width > size.height;
  if (size.width >= 900) return true;
  if (isLand && size.width >= 680) return true;
  return false;
}

int responsiveGridColumns(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  if (w >= 1100) return 3;
  if (isMultiColumnLayout(context)) return 2;
  return 1;
}

/// Scales layout values from a phone baseline while keeping them within
/// practical bounds for very small and very large windows.
double responsiveValue(
  BuildContext context,
  double value, {
  double minScale = 0.88,
  double maxScale = 1.18,
}) {
  final width = MediaQuery.sizeOf(context).width;
  final scale = (width / 390.0).clamp(minScale, maxScale);
  return value * scale;
}

double responsiveFontSize(BuildContext context, double size) =>
    responsiveValue(context, size, minScale: 0.92, maxScale: 1.10);

EdgeInsets responsiveInsets(
  BuildContext context, {
  double horizontal = 16,
  double vertical = 16,
}) {
  return EdgeInsets.symmetric(
    horizontal: responsiveValue(context, horizontal),
    vertical: responsiveValue(context, vertical),
  );
}
