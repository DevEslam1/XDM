import 'package:dio/dio.dart';
import 'package:dmx/core/services/retry_interceptor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProfessionalRetryInterceptor Unit Tests', () {
    test('ProfessionalRetryInterceptor constructs with Dio instance', () {
      final dio = Dio();
      final interceptor = ProfessionalRetryInterceptor(dio);
      expect(interceptor, isNotNull);
    });
  });
}
