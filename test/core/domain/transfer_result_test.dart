import 'package:dmx/core/domain/transfer_result.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TransferResult', () {
    test('success constructor and getters', () {
      const r = TransferResult.success(message: 'ok');
      expect(r.status, TransferResultStatus.success);
      expect(r.isSuccess, isTrue);
      expect(r.isFailure, isFalse);
      expect(r.isCancelled, isFalse);
      expect(r.isPaused, isFalse);
      expect(r.retryable, isFalse);
      expect(r.recoveryAction, RecoveryAction.ignore);
      expect(r.message, 'ok');
    });

    test('failure constructor and getters', () {
      const r = TransferResult.failure(
        taxonomyCode: 'net',
        retryable: true,
        message: 'bad',
        httpStatus: 500,
      );
      expect(r.status, TransferResultStatus.failed);
      expect(r.isFailure, isTrue);
      expect(r.taxonomyCode, 'net');
      expect(r.retryable, isTrue);
      expect(r.httpStatus, 500);
      expect(r.recoveryAction, RecoveryAction.retryWithDelay);
    });

    test('cancelled and paused constructors', () {
      const c = TransferResult.cancelled();
      expect(c.status, TransferResultStatus.cancelled);
      expect(c.isCancelled, isTrue);
      expect(c.taxonomyCode, 'cancelled');
      expect(c.message, 'Cancelled');

      const p = TransferResult.paused();
      expect(p.status, TransferResultStatus.paused);
      expect(p.isPaused, isTrue);
      expect(p.taxonomyCode, 'paused');
      expect(p.message, 'Paused');

      expect(const TransferResult.cancelled(message: 'x').message, 'x');
      expect(const TransferResult.paused(message: 'y').message, 'y');
    });

    test('toMap', () {
      const r = TransferResult.failure(
        taxonomyCode: 'net',
        retryable: true,
        message: 'bad',
        httpStatus: 500,
      );
      final map = r.toMap();
      expect(map['status'], 'failed');
      expect(map['taxonomyCode'], 'net');
      expect(map['retryable'], isTrue);
      expect(map['httpStatus'], 500);
      expect(map['recoveryAction'], 'retryWithDelay');
    });

    test('fromMap for all statuses', () {
      final success = TransferResult.fromMap(const {
        'status': 'success',
        'message': 'ok',
      });
      expect(success.status, TransferResultStatus.success);

      final cancelled = TransferResult.fromMap(const {
        'status': 'cancelled',
        'message': 'stop',
      });
      expect(cancelled.status, TransferResultStatus.cancelled);
      expect(cancelled.message, 'stop');

      final paused = TransferResult.fromMap(const {'status': 'paused'});
      expect(paused.status, TransferResultStatus.paused);
      expect(paused.message, 'Paused');

      final failed = TransferResult.fromMap(const {
        'status': 'failed',
        'taxonomyCode': 'disk',
        'retryable': true,
        'message': 'full',
        'httpStatus': 507,
        'recoveryAction': 'showSettings',
      });
      expect(failed.status, TransferResultStatus.failed);
      expect(failed.taxonomyCode, 'disk');
      expect(failed.retryable, isTrue);
      expect(failed.httpStatus, 507);
      expect(failed.recoveryAction, RecoveryAction.showSettings);
    });

    test('fromMap fallbacks', () {
      final unknownStatus = TransferResult.fromMap(const {});
      expect(unknownStatus.status, TransferResultStatus.failed);
      expect(unknownStatus.taxonomyCode, 'unknown');
      expect(unknownStatus.message, 'Transfer failed');

      final legacy = TransferResult.fromMap(const {
        'status': 'failed',
        'errorMessage': 'legacy msg',
        'errorStatus': 404,
        'errorType': 'http',
      });
      expect(legacy.message, 'legacy msg');
      expect(legacy.httpStatus, 404);
      expect(legacy.taxonomyCode, 'http');
    });

    test('toString', () {
      const r = TransferResult.success(message: 'ok');
      expect(r.toString(), contains('TransferResult'));
      expect(r.toString(), contains('success'));
    });
  });
}
