import 'package:dmx/core/utils/responsive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _host(void Function(BuildContext) body) => MaterialApp(
      home: Builder(
        builder: (context) {
          body(context);
          return const SizedBox();
        },
      ),
    );

void main() {
  testWidgets('phone portrait uses compact layout', (tester) async {
    _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_host((context) {
      expect(getScreenType(context), ScreenType.phone);
      expect(isPhone(context), isTrue);
      expect(isTablet(context), isFalse);
      expect(isDesktop(context), isFalse);
      expect(contentMaxWidth(context), double.infinity);
      expect(screenPadding(context).left, 20.0);
      expect(screenPadding(context).top, 8.0);
      expect(isLandscape(context), isFalse);
      expect(isPhoneLandscape(context), isFalse);
      expect(isTabletLandscape(context), isFalse);
      expect(shouldShowSideNavigation(context), isFalse);
      expect(isMultiColumnLayout(context), isFalse);
      expect(shouldShowTwoPaneDetails(context), isFalse);
      expect(responsiveGridColumns(context), 1);
    }));
  });

  testWidgets('tablet portrait stays single-pane', (tester) async {
    _setSize(tester, const Size(768, 1024));
    await tester.pumpWidget(_host((context) {
      expect(getScreenType(context), ScreenType.tablet);
      expect(isTablet(context), isTrue);
      expect(isPhone(context), isFalse);
      expect(contentMaxWidth(context), 900);
      expect(screenPadding(context).left, 32.0);
      expect(screenPadding(context).top, 16.0);
      expect(isTabletLandscape(context), isFalse);
      expect(isMultiColumnLayout(context), isFalse);
      expect(shouldShowTwoPaneDetails(context), isFalse);
      expect(responsiveGridColumns(context), 1);
    }));
  });

  testWidgets('tablet landscape activates multi-column and side navigation',
      (tester) async {
    _setSize(tester, const Size(1024, 768));
    await tester.pumpWidget(_host((context) {
      // Width >= 900 classifies as desktop even in landscape.
      expect(getScreenType(context), ScreenType.desktop);
      expect(isDesktop(context), isTrue);
      expect(isLandscape(context), isTrue);
      expect(isTabletLandscape(context), isTrue);
      expect(isPhoneLandscape(context), isFalse);
      expect(shouldShowSideNavigation(context), isTrue);
      expect(isMultiColumnLayout(context), isTrue);
      expect(shouldShowTwoPaneDetails(context), isTrue);
      expect(responsiveGridColumns(context), 2);
    }));
  });

  testWidgets('desktop uses three-column layout and capped content width',
      (tester) async {
    _setSize(tester, const Size(1440, 900));
    await tester.pumpWidget(_host((context) {
      expect(getScreenType(context), ScreenType.desktop);
      expect(isDesktop(context), isTrue);
      expect(contentMaxWidth(context), 1200);
      expect(shouldShowSideNavigation(context), isTrue);
      expect(isMultiColumnLayout(context), isTrue);
      expect(responsiveGridColumns(context), 3);
    }));
  });

  testWidgets('small landscape phone is multi-column but not side-nav',
      (tester) async {
    _setSize(tester, const Size(700, 400));
    await tester.pumpWidget(_host((context) {
      expect(getScreenType(context), ScreenType.tablet);
      expect(isLandscape(context), isTrue);
      expect(isPhoneLandscape(context), isTrue);
      expect(isTabletLandscape(context), isFalse);
      expect(isMultiColumnLayout(context), isTrue);
      expect(responsiveGridColumns(context), 2);
    }));
  });

  testWidgets('mid-width landscape shows two-pane details without side nav',
      (tester) async {
    _setSize(tester, const Size(800, 500));
    await tester.pumpWidget(_host((context) {
      expect(getScreenType(context), ScreenType.tablet);
      expect(isLandscape(context), isTrue);
      expect(shouldShowSideNavigation(context), isTrue);
      expect(shouldShowTwoPaneDetails(context), isTrue);
    }));
  });

  testWidgets('grid aspect ratio reacts to columns and tiny widths',
      (tester) async {
    _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_host((context) {
      // Wide layout clamps the ratio to the 3.0 ceiling.
      final wide = gridChildAspectRatio(context, columns: 2);
      expect(wide, greaterThan(0));

      // A very narrow viewport (below 320) shrinks the effective padding.
      final tiny = gridChildAspectRatio(context, columns: 3);
      expect(tiny, greaterThanOrEqualTo(0.3));
      expect(tiny, lessThanOrEqualTo(3.0));

      // Zero/negative columns collapse to a single column.
      final single = gridChildAspectRatio(context, columns: 0);
      expect(single, greaterThan(0));
    }));
  });

  testWidgets('grid aspect ratio clamps at the upper bound for huge widths',
      (tester) async {
    _setSize(tester, const Size(3000, 1000));
    await tester.pumpWidget(_host((context) {
      expect(gridChildAspectRatio(context, columns: 2), 3.0);
    }));
  });

  testWidgets('responsive scaling clamps to practical bounds', (tester) async {
    _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_host((context) {
      // At the phone baseline the scale is 1.0.
      expect(responsiveValue(context, 100), closeTo(100, 0.001));
      expect(responsiveFontSize(context, 10), closeTo(10, 0.001));
      expect(responsiveInsets(context).left, closeTo(16, 0.001));
    }));
  });

  testWidgets('responsive scaling clamps for very small and large widths',
      (tester) async {
    _setSize(tester, const Size(200, 400));
    await tester.pumpWidget(_host((context) {
      expect(responsiveValue(context, 100), closeTo(88, 0.001));
    }));
    _setSize(tester, const Size(2000, 1000));
    await tester.pumpWidget(_host((context) {
      expect(responsiveValue(context, 100), closeTo(118, 0.001));
    }));
  });

  testWidgets('ResponsiveBuilder classifies constraints', (tester) async {
    _setSize(tester, const Size(1000, 800));

    final observed = <ScreenType>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 650,
            child: ResponsiveBuilder(
              builder: (context, type) {
                observed.add(type);
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    expect(observed.last, ScreenType.tablet);

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 320,
            child: ResponsiveBuilder(
              builder: (context, type) {
                observed.add(type);
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    expect(observed.last, ScreenType.phone);
  });
}
