import 'package:dmx/features/browser/widgets/smart_url_bar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_services.dart';
import '../helpers/test_helpers.dart';

void main() {
  setUp(() {
    setupTestPluginMocks();
  });

  Future<void> pumpBar(
    WidgetTester tester, {
    required TextEditingController controller,
    required FocusNode focusNode,
    bool isDark = true,
    bool isLoading = false,
    double progress = 0.0,
    bool isHttps = false,
    VoidCallback? onReload,
    VoidCallback? onStopLoading,
    VoidCallback? onShieldPressed,
    void Function(String)? onNavigate,
    FakeDatabaseService? database,
  }) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(createTestApp(
      child: Center(
        child: SmartUrlBar(
          controller: controller,
          focusNode: focusNode,
          isDark: isDark,
          isLoading: isLoading,
          progress: progress,
          isHttps: isHttps,
          onReload: onReload,
          onStopLoading: onStopLoading,
          onShieldPressed: onShieldPressed,
          onNavigate: onNavigate ?? (_) {},
        ),
      ),
      databaseService: database,
    ));
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('renders hint and shield when idle', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();

    await pumpBar(tester, controller: controller, focusNode: focusNode);

    expect(find.byType(SmartUrlBar), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.shield_outlined), findsOneWidget);

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('https state shows lock icon', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      isHttps: true,
    );

    expect(find.byIcon(Icons.lock_rounded), findsOneWidget);

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('shield callback fires when pressed', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    var pressed = 0;

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      onShieldPressed: () => pressed++,
    );

    await tester.tap(find.byIcon(Icons.shield_outlined));
    await tester.pump(const Duration(milliseconds: 50));

    expect(pressed, 1);

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('reload callback fires from refresh button', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    var reloaded = 0;

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      onReload: () => reloaded++,
    );

    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pump(const Duration(milliseconds: 50));

    expect(reloaded, 1);

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('stop loading callback fires while loading', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    var stopped = 0;

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      isLoading: true,
      progress: 0.4,
      onStopLoading: () => stopped++,
    );

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump(const Duration(milliseconds: 50));

    expect(stopped, 1);

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('typing generates overlay suggestions and navigates',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    String? navigatedTo;

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      onNavigate: (u) => navigatedTo = u,
    );

    await tester.enterText(find.byType(TextField), 'example.com');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('https://example.com'), findsOneWidget);

    await tester.tap(find.text('https://example.com').last);
    await tester.pump(const Duration(milliseconds: 100));

    expect(navigatedTo, 'https://example.com');

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('submitting text navigates', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    String? navigatedTo;

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      onNavigate: (u) => navigatedTo = u,
    );

    await tester.enterText(find.byType(TextField), 'flutter.dev');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 100));

    expect(navigatedTo, 'flutter.dev');

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('clear button empties the controller when focused with text',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();

    await pumpBar(tester, controller: controller, focusNode: focusNode);

    focusNode.requestFocus();
    await tester.pump(const Duration(milliseconds: 20));
    controller.text = 'hello';
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump(const Duration(milliseconds: 20));

    expect(controller.text, isEmpty);

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('search-only query produces a search suggestion', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();

    await pumpBar(tester, controller: controller, focusNode: focusNode);

    await tester.enterText(find.byType(TextField), 'hello world');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Search'), findsWidgets);

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('dark/light + loading transitions update widget', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      isLoading: true,
      progress: 0.2,
    );
    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      isDark: false,
      isHttps: true,
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(SmartUrlBar), findsOneWidget);

    controller.dispose();
    focusNode.dispose();
  });
}
