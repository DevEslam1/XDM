import 'dart:async';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/mirror/mirror_selector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MirrorSelector.raceMirrors', () {
    test('throws ArgumentError if url list is empty', () async {
      expect(
        () => MirrorSelector.raceMirrors([], (url, cancel) async => 'data'),
        throwsArgumentError,
      );
    });

    test('single mirror wins on success', () async {
      final res = await MirrorSelector.raceMirrors(
        ['https://mirror1.com'],
        (url, cancel) async => 'success_single',
      );
      expect(res, 'success_single');
    });

    test('single mirror propagates error on failure', () async {
      expect(
        () => MirrorSelector.raceMirrors(
          ['https://mirror1.com'],
          (url, cancel) async => throw Exception('single fail'),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('first mirror wins and cancels remaining tokens', () async {
      final tokens = <String, CancelToken>{};
      final completers = <String, Completer<String>>{
        'm1': Completer<String>(),
        'm2': Completer<String>(),
        'm3': Completer<String>(),
      };

      final future = MirrorSelector.raceMirrors<String>(
        ['m1', 'm2', 'm3'],
        (url, cancelToken) {
          tokens[url] = cancelToken;
          return completers[url]!.future;
        },
      );

      // m2 wins first
      completers['m2']!.complete('m2_wins');
      final result = await future;

      expect(result, 'm2_wins');
      expect(tokens['m2']!.isCancelled, isFalse);
      expect(tokens['m1']!.isCancelled, isTrue);
      expect(tokens['m3']!.isCancelled, isTrue);
    });

    test('all mirrors fail -> throws MirrorRaceException with aggregate errors',
        () async {
      final tokens = <CancelToken>[];

      expect(
        () => MirrorSelector.raceMirrors<String>(
          ['m1', 'm2', 'm3'],
          (url, cancelToken) async {
            tokens.add(cancelToken);
            throw Exception('failure from $url');
          },
        ),
        throwsA(
          isA<MirrorRaceException>().having(
            (e) => e.errors.length,
            'errors count',
            3,
          ),
        ),
      );
    });

    test(
        'mixed success and failure returns winner and cancels slower/failed tokens',
        () async {
      final tokens = <String, CancelToken>{};

      final result = await MirrorSelector.raceMirrors<String>(
        ['slow', 'fast_success', 'immediate_fail'],
        (url, cancelToken) async {
          tokens[url] = cancelToken;
          if (url == 'immediate_fail') {
            throw Exception('immediate drop');
          }
          if (url == 'fast_success') {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return 'fast_value';
          }
          // slow
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return 'slow_value';
        },
      );

      expect(result, 'fast_value');
      expect(tokens['slow']!.isCancelled, isTrue);
    });

    test('timeout cancels all tokens and completes with TimeoutException',
        () async {
      final tokens = <CancelToken>[];

      expect(
        () => MirrorSelector.raceMirrors<String>(
          ['m1', 'm2'],
          (url, cancelToken) {
            tokens.add(cancelToken);
            return Completer<String>().future; // never finishes
          },
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<TimeoutException>()),
      );

      await Future<void>.delayed(const Duration(milliseconds: 80));
      for (final t in tokens) {
        expect(t.isCancelled, isTrue);
      }
    });

    test('parent CancelToken cancels all racing tokens and aborts', () async {
      final parentCancel = CancelToken();
      final tokens = <CancelToken>[];

      final future = MirrorSelector.raceMirrors<String>(
        ['m1', 'm2'],
        (url, cancelToken) {
          tokens.add(cancelToken);
          return Completer<String>().future;
        },
        parentCancelToken: parentCancel,
      );

      parentCancel.cancel('user_aborted');

      expect(future, throwsA(anything));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      for (final t in tokens) {
        expect(t.isCancelled, isTrue);
      }
    });

    test('synchronous exceptions inside fetch do not deadlock race', () async {
      expect(
        () => MirrorSelector.raceMirrors<String>(
          ['m1', 'm2'],
          (url, cancelToken) {
            throw FormatException('sync crash on $url');
          },
        ),
        throwsA(isA<MirrorRaceException>()),
      );
    });
  });
}
