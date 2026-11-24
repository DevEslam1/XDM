import 'package:dmx/core/domain/models/error_family.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ErrorFamily', () {
    test('contains all expected families', () {
      expect(ErrorFamily.values, hasLength(9));
      expect(
        ErrorFamily.values.map((e) => e.name),
        [
          'network',
          'server',
          'auth',
          'disk',
          'integrity',
          'cancelled',
          'timeout',
          'parse',
          'unknown',
        ],
      );
    });
  });
}
