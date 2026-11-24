import 'package:dmx/core/di/injection.dart';
import 'package:dmx/core/domain/subscription/subscription_status.dart';
import 'package:dmx/core/domain/subscription/subscription_tier.dart';
import 'package:dmx/core/services/subscription/subscription_guard.dart';
import 'package:dmx/core/services/subscription/subscription_service.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

class _GuardHost extends StatefulWidget {
  const _GuardHost({required this.onResult});

  final void Function(bool) onResult;

  @override
  State<_GuardHost> createState() => _GuardHostState();
}

class _GuardHostState extends State<_GuardHost>
    with SubscriptionGuard<_GuardHost> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Text('tier:${currentTier.id}'),
          Text('status:${subscriptionStatus.name}'),
          Text('premium:$isPremium'),
          ElevatedButton(
            onPressed: () =>
                widget.onResult(checkEntitlement('torrent_support')),
            child: const Text('entitlement'),
          ),
          ElevatedButton(
            onPressed: () => widget.onResult(checkDownloadLimit(3)),
            child: const Text('limit3'),
          ),
          ElevatedButton(
            onPressed: () => widget.onResult(checkDownloadLimit(0)),
            child: const Text('limit0'),
          ),
        ],
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SubscriptionService service;
  bool? result;

  setUp(() {
    result = null;
    service = SubscriptionService();
    getIt.registerSingleton<SubscriptionService>(service);
  });

  tearDown(() async {
    await getIt.reset();
  });

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: SettingsProvider(),
        child: MaterialApp(
          routes: {'/subscription': (_) => const Scaffold(body: Text('plans'))},
          home: _GuardHost(onResult: (r) => result = r),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('premium user passes entitlement and limit checks',
      (tester) async {
    await service.init(); // purchases disabled -> unlocks premium
    expect(service.isPremium, isTrue);

    await pumpHost(tester);

    expect(find.text('tier:${SubscriptionTier.premium.id}'), findsOneWidget);
    expect(find.text('premium:true'), findsOneWidget);
    expect(
        find.text('status:${SubscriptionStatus.active.name}'), findsOneWidget);

    await tester.tap(find.text('entitlement'));
    await tester.pumpAndSettle();
    expect(result, isTrue);

    await tester.tap(find.text('limit3'));
    await tester.pumpAndSettle();
    expect(result, isTrue);

    await tester.tap(find.text('limit0'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('free user is blocked and shown the upgrade prompt',
      (tester) async {
    await pumpHost(tester);

    expect(find.text('premium:false'), findsOneWidget);

    await tester.tap(find.text('entitlement'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);

    // The primary action dismisses the sheet and routes to the plans screen.
    await tester.tap(find.text('View Plans'));
    await tester.pumpAndSettle();
    expect(find.text('plans'), findsOneWidget);
  });

  testWidgets('free user at the download limit is shown the limit prompt',
      (tester) async {
    await pumpHost(tester);

    await tester.tap(find.text('limit3'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);

    await tester.tap(find.text('Upgrade Now'));
    await tester.pumpAndSettle();
    expect(find.text('plans'), findsOneWidget);
  });

  testWidgets('free user below the limit is allowed', (tester) async {
    await pumpHost(tester);

    await tester.tap(find.text('limit0'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
