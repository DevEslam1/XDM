import 'package:flutter/material.dart';

enum ScreenType { phone, tablet, desktop }

ScreenType getScreenType(BuildContext context) {
  final w = MediaQuery.of(context).size.width;
  if (w >= 900) return ScreenType.desktop;
  if (w >= 600) return ScreenType.tablet;
  return ScreenType.phone;
}

bool isTablet(BuildContext context) => getScreenType(context) != ScreenType.phone;
bool isPhone(BuildContext context) => getScreenType(context) == ScreenType.phone;
bool isDesktop(BuildContext context) => getScreenType(context) == ScreenType.desktop;

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
  final h = type == ScreenType.phone ? 16.0 : 32.0;
  final v = type == ScreenType.phone ? 8.0 : 16.0;
  return EdgeInsets.symmetric(horizontal: h, vertical: v);
}

const double kGridTileHeight = 140.0;
const double kGridTileGap = 24.0;

double gridChildAspectRatio(BuildContext context, {int columns = 2, double horizontalPadding = 32.0}) {
  final w = MediaQuery.of(context).size.width;
  final availableWidth = w - horizontalPadding * 2;
  // There are (columns - 1) gaps between `columns` tiles in a row, not one
  // gap per tile — subtracting a full gap per column (the previous formula)
  // made every tile narrower than intended, increasingly so as columns grew.
  final tileWidth = (availableWidth - kGridTileGap * (columns - 1)) / columns;
  final ratio = tileWidth / kGridTileHeight;
  return ratio.clamp(0.3, 3.0);
}
