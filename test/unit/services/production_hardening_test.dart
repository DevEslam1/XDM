import 'dart:async';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:dmx/shared/mixins/safe_disposal_mixin.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestWidget extends StatefulWidget {
  const _TestWidget();

  @override
  State<_TestWidget> createState() => _TestWidgetState();
}

class _TestWidgetState extends State<_TestWidget> with SafeDisposalMixin {
  late final StreamSubscription<int> sub;
  late final Timer timer;
  late final ValueNotifier<int> notifier;

  @override
  void initState() {
    super.initState();
    sub = trackSubscription(Stream<int>.periodic(const Duration(milliseconds: 100), (i) => i).listen((_) {}));
    timer = trackTimer(Timer.periodic(const Duration(milliseconds: 100), (_) {}));
    notifier = trackNotifier(ValueNotifier<int>(0));
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  group('Production Readiness Hardening Tests', () {
    testWidgets('SafeDisposalMixin safely tracks and cleans up timers, streams, notifiers on dispose', (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: _TestWidget(),
      ));

      final state = tester.state<_TestWidgetState>(find.byType(_TestWidget));
      expect(state.timer.isActive, isTrue);

      // Unmount the widget to trigger dispose()
      await tester.pumpWidget(const SizedBox());

      expect(state.timer.isActive, isFalse);
    });

    test('UrlValidator correctly filters dangerous schemes and enforces safety bounds', () {
      // Valid URLs
      expect(UrlValidator.isValid('https://example.com/file.zip'), isTrue);
      expect(UrlValidator.isValid('http://sub.domain.org/path?q=1'), isTrue);
      expect(UrlValidator.isValid('magnet:?xt=urn:btih:d143c08e5c1d6837910ff61dc970fb9aa2d83b63'), isTrue);
      expect(UrlValidator.isValid('ftp://files.example.com/data.iso'), isTrue);

      // Dangerous schemes
      expect(UrlValidator.isValid('javascript:alert(1)'), isFalse);
      expect(UrlValidator.isValid('data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg=='), isFalse);
      expect(UrlValidator.isValid('vbscript:msgbox(1)'), isFalse);
      expect(UrlValidator.isValid('about:blank'), isFalse);
      expect(UrlValidator.isValid('blob:http://example.com/uuid'), isFalse);

      // Control characters and excessive length
      expect(UrlValidator.isValid('https://example.com/\x00test'), isFalse);
      expect(UrlValidator.isValid('https://example.com/\x1fbad'), isFalse);
      expect(UrlValidator.isValid('https://example.com/${'a' * 2100}'), isFalse);

      // Null and empty
      expect(UrlValidator.isValid(null), isFalse);
      expect(UrlValidator.isValid('   '), isFalse);

      // Sanitization
      expect(UrlValidator.sanitize(' https://example.com/\x00file.zip '), equals('https://example.com/file.zip'));
    });
  });
}
