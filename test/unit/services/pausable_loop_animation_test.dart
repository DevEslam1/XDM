import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/shared/mixins/pausable_loop_animation.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestWidget extends StatefulWidget {
  const _TestWidget();

  @override
  State<_TestWidget> createState() => _TestWidgetState();
}

class _TestWidgetState extends State<_TestWidget>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        PausableLoopAnimation<_TestWidget> {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  @override
  AnimationController get loopController => _controller;

  @override
  void initState() {
    super.initState();
    startPausableLoop();
  }

  @override
  void dispose() {
    stopPausableLoop();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PausableLoopAnimation Tests', () {
    late SettingsProvider settings;

    setUp(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => null,
      );
      SharedPreferences.setMockInitialValues({});
      settings = SettingsProvider.instance;
      await settings.load();
    });

    testWidgets('Battery saver on -> loopWanted returns false', (tester) async {
      await settings.setBatterySaverMode(true);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: _TestWidget(),
        ),
      );

      final state = tester.state<_TestWidgetState>(find.byType(_TestWidget));
      expect(state.loopWanted, isFalse);
    });

    testWidgets('App backgrounded -> loopWanted/sync pauses loop',
        (tester) async {
      await settings.setBatterySaverMode(false);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: _TestWidget(),
        ),
      );

      final state = tester.state<_TestWidgetState>(find.byType(_TestWidget));
      expect(state.loopWanted, isTrue);

      // Simulate app going to background
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(state.loopController.isAnimating, isFalse);
    });

    testWidgets('Battery saver off + app foreground -> loopWanted returns true',
        (tester) async {
      await settings.setBatterySaverMode(false);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: _TestWidget(),
        ),
      );

      final state = tester.state<_TestWidgetState>(find.byType(_TestWidget));
      expect(state.loopWanted, isTrue);
    });
  });
}
