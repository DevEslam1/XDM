import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dmx/core/domain/subscription/subscription_status.dart';
import 'package:dmx/core/services/subscription/sub_club_api_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDio extends Mock implements Dio {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockDio dio;

  setUp(() {
    dio = MockDio();
  });

  Response<dynamic> response({
    required int statusCode,
    dynamic data,
    String path = '/test',
  }) =>
      Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: statusCode,
        data: data,
      );

  group('SubClubValidationResponse', () {
    test('fromJson parses every known status', () {
      expect(
        SubClubValidationResponse.fromJson({'status': 'active'}).status,
        SubscriptionStatus.active,
      );
      expect(
        SubClubValidationResponse.fromJson({'status': 'trial'}).status,
        SubscriptionStatus.trial,
      );
      expect(
        SubClubValidationResponse.fromJson({'status': 'expired'}).status,
        SubscriptionStatus.expired,
      );
      expect(
        SubClubValidationResponse.fromJson({'status': 'cancelled'}).status,
        SubscriptionStatus.cancelled,
      );
      expect(
        SubClubValidationResponse.fromJson({'status': 'free'}).status,
        SubscriptionStatus.free,
      );
      expect(
        SubClubValidationResponse.fromJson({'status': 'bogus'}).status,
        SubscriptionStatus.unknown,
      );
      expect(
        SubClubValidationResponse.fromJson({'status': null}).status,
        SubscriptionStatus.unknown,
      );
    });

    test('fromJson maps optional fields and defaults', () {
      final r = SubClubValidationResponse.fromJson({
        'status': 'active',
        'expires_at': '2030-01-01T00:00:00.000Z',
        'plan_id': 'premium',
        'in_grace_period': true,
        'metadata': {'a': 1},
      });
      expect(r.expiresAt, '2030-01-01T00:00:00.000Z');
      expect(r.planId, 'premium');
      expect(r.isInGracePeriod, isTrue);
      expect(r.metadata, {'a': 1});

      final defaults = SubClubValidationResponse.fromJson({'status': 'free'});
      expect(defaults.isInGracePeriod, isFalse);
      expect(defaults.metadata, isEmpty);
    });

    test('toString is descriptive', () {
      const r = SubClubValidationResponse(
        status: SubscriptionStatus.active,
        expiresAt: 'x',
        planId: 'p',
      );
      expect(r.toString(), contains('active'));
      expect(r.toString(), contains('plan=p'));
    });
  });

  group('SubClubApiClient', () {
    test('validateReceipt posts and parses a 200 response', () async {
      when(() => dio.post(any(),
              data: any(named: 'data'), options: any(named: 'options')))
          .thenAnswer((_) async => response(
                statusCode: 200,
                data: <String, dynamic>{
                  'status': 'active',
                  'plan_id': 'monthly',
                },
              ));

      final client = SubClubApiClient(dio: dio);
      final result = await client.validateReceipt('receipt-1');

      expect(result.status, SubscriptionStatus.active);
      expect(result.planId, 'monthly');
      verify(() => dio.post(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
          )).called(1);
    });

    test('restorePurchases posts platform and token', () async {
      when(() => dio.post(any(),
              data: any(named: 'data'), options: any(named: 'options')))
          .thenAnswer((_) async => response(
                statusCode: 200,
                data: <String, dynamic>{'status': 'trial'},
              ));

      final client = SubClubApiClient(dio: dio);
      final result = await client.restorePurchases(
        platform: 'ios',
        accountToken: 'token',
      );

      expect(result.status, SubscriptionStatus.trial);
      final captured = verify(() => dio.post(
            any(),
            data: captureAny(named: 'data'),
            options: any(named: 'options'),
          )).captured.single as Map<String, dynamic>;
      expect(captured['platform'], 'ios');
      expect(captured['account_token'], 'token');
    });

    test('4xx is not retried and returns unknown', () async {
      when(() => dio.post(any(),
              data: any(named: 'data'), options: any(named: 'options')))
          .thenAnswer(
              (_) async => response(statusCode: 404, data: 'not found'));

      final client = SubClubApiClient(dio: dio);
      final result = await client.validateReceipt('r');

      expect(result.status, SubscriptionStatus.unknown);
      verify(() => dio.post(any(),
          data: any(named: 'data'), options: any(named: 'options'))).called(1);
    });

    test('5xx retries then gives up after maxRetries', () {
      fakeAsync((async) {
        when(() => dio.post(any(),
                data: any(named: 'data'), options: any(named: 'options')))
            .thenAnswer((_) async => response(statusCode: 503, data: 'down'));

        final client = SubClubApiClient(dio: dio);
        SubClubValidationResponse? result;
        client.validateReceipt('r').then((r) => result = r);
        async.elapse(const Duration(seconds: 30));

        expect(result, isNotNull);
        expect(result!.status, SubscriptionStatus.unknown);
        verify(() => dio.post(any(),
            data: any(named: 'data'),
            options: any(named: 'options'))).called(3);
      });
    });

    test('timeout retries then gives up', () {
      fakeAsync((async) {
        when(() => dio.post(any(),
                data: any(named: 'data'), options: any(named: 'options')))
            .thenThrow(TimeoutException('slow'));

        final client = SubClubApiClient(dio: dio);
        SubClubValidationResponse? result;
        client.validateReceipt('r').then((r) => result = r);
        async.elapse(const Duration(seconds: 30));

        expect(result, isNotNull);
        expect(result!.status, SubscriptionStatus.unknown);
        verify(() => dio.post(any(),
            data: any(named: 'data'),
            options: any(named: 'options'))).called(3);
      });
    });

    test('DioException returns unknown without retrying', () async {
      when(() => dio.post(any(),
              data: any(named: 'data'), options: any(named: 'options')))
          .thenThrow(DioException(requestOptions: RequestOptions(path: '/x')));

      final client = SubClubApiClient(dio: dio);
      final result = await client.validateReceipt('r');
      expect(result.status, SubscriptionStatus.unknown);
      verify(() => dio.post(any(),
          data: any(named: 'data'), options: any(named: 'options'))).called(1);
    });

    test('generic error returns unknown without retrying', () async {
      when(() => dio.post(any(),
          data: any(named: 'data'),
          options: any(named: 'options'))).thenThrow(StateError('boom'));

      final client = SubClubApiClient(dio: dio);
      final result = await client.validateReceipt('r');
      expect(result.status, SubscriptionStatus.unknown);
    });

    test('checkEntitlement returns true for premium status', () async {
      when(() => dio.post(any(),
              data: any(named: 'data'), options: any(named: 'options')))
          .thenAnswer((_) async => response(
                statusCode: 200,
                data: <String, dynamic>{'status': 'active'},
              ));

      final client = SubClubApiClient(dio: dio);
      expect(
        await client.checkEntitlement(receipt: 'r', entitlementKey: 'k'),
        isTrue,
      );
    });

    test('checkEntitlement returns false on error', () async {
      when(() => dio.post(any(),
              data: any(named: 'data'), options: any(named: 'options')))
          .thenThrow(DioException(requestOptions: RequestOptions(path: '/x')));

      final client = SubClubApiClient(dio: dio);
      expect(
        await client.checkEntitlement(receipt: 'r', entitlementKey: 'k'),
        isFalse,
      );
    });

    test('getServerTime parses a 200 response', () async {
      when(() => dio.get(any(), options: any(named: 'options'))).thenAnswer(
        (_) async => response(
          statusCode: 200,
          data: <String, dynamic>{'time': '2030-01-01T00:00:00.000Z'},
        ),
      );

      final client = SubClubApiClient(dio: dio);
      final time = await client.getServerTime();
      expect(time, DateTime.parse('2030-01-01T00:00:00.000Z'));
    });

    test('getServerTime returns null on non-200', () async {
      when(() => dio.get(any(), options: any(named: 'options'))).thenAnswer(
        (_) async => response(statusCode: 500, data: 'oops'),
      );

      final client = SubClubApiClient(dio: dio);
      expect(await client.getServerTime(), isNull);
    });

    test('getServerTime returns null when the request throws', () async {
      when(() => dio.get(any(), options: any(named: 'options')))
          .thenThrow(DioException(requestOptions: RequestOptions(path: '/x')));

      final client = SubClubApiClient(dio: dio);
      expect(await client.getServerTime(), isNull);
    });

    test('apiKey is sent as a bearer header', () async {
      when(() => dio.post(any(),
              data: any(named: 'data'), options: any(named: 'options')))
          .thenAnswer((_) async => response(
                statusCode: 200,
                data: <String, dynamic>{'status': 'free'},
              ));

      final client = SubClubApiClient(dio: dio, apiKey: 'secret');
      await client.validateReceipt('r');

      final options = verify(() => dio.post(
            any(),
            data: any(named: 'data'),
            options: captureAny(named: 'options'),
          )).captured.single as Options;
      expect(options.headers!['Authorization'], 'Bearer secret');
    });

    test('dispose force-closes the dio client', () {
      final client = SubClubApiClient(dio: dio);
      client.dispose();
      verify(() => dio.close(force: true)).called(1);
    });
  });
}
