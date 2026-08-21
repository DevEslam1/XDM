import 'package:flutter/foundation.dart';
import '../services/error_taxonomy.dart';

enum TransferResultStatus {
  success,
  failed,
  cancelled,
  paused,
}

@immutable
class TransferResult {
  final TransferResultStatus status;
  final String? taxonomyCode;
  final bool retryable;
  final String? message;
  final int? httpStatus;
  final RecoveryAction recoveryAction;
  final Object? error;

  const TransferResult.success({this.message})
      : status = TransferResultStatus.success,
        taxonomyCode = null,
        retryable = false,
        httpStatus = null,
        recoveryAction = RecoveryAction.ignore,
        error = null;

  const TransferResult.failure({
    required this.taxonomyCode,
    required this.retryable,
    required this.message,
    this.httpStatus,
    this.recoveryAction = RecoveryAction.retryWithDelay,
    this.error,
  }) : status = TransferResultStatus.failed;

  const TransferResult.cancelled({this.message = 'Cancelled'})
      : status = TransferResultStatus.cancelled,
        taxonomyCode = 'cancelled',
        retryable = false,
        httpStatus = null,
        recoveryAction = RecoveryAction.ignore,
        error = null;

  const TransferResult.paused({this.message = 'Paused'})
      : status = TransferResultStatus.paused,
        taxonomyCode = 'paused',
        retryable = false,
        httpStatus = null,
        recoveryAction = RecoveryAction.ignore,
        error = null;

  bool get isSuccess => status == TransferResultStatus.success;
  bool get isFailure => status == TransferResultStatus.failed;
  bool get isCancelled => status == TransferResultStatus.cancelled;
  bool get isPaused => status == TransferResultStatus.paused;

  Map<String, dynamic> toMap() => {
        'status': status.name,
        'taxonomyCode': taxonomyCode,
        'retryable': retryable,
        'message': message,
        'httpStatus': httpStatus,
        'recoveryAction': recoveryAction.name,
      };

  factory TransferResult.fromMap(Map<String, dynamic> map) {
    final statusName = map['status'] as String? ?? 'failed';
    final status = TransferResultStatus.values.firstWhere(
      (s) => s.name == statusName,
      orElse: () => TransferResultStatus.failed,
    );
    final taxonomyCode = map['taxonomyCode'] as String?;
    final retryable = map['retryable'] as bool? ?? false;
    final message = map['message'] as String? ?? map['errorMessage'] as String?;
    final httpStatus = (map['httpStatus'] as num?)?.toInt() ??
        (map['errorStatus'] as num?)?.toInt();
    final actionName = map['recoveryAction'] as String?;
    final recoveryAction = RecoveryAction.values.firstWhere(
      (a) => a.name == actionName,
      orElse: () => RecoveryAction.ignore,
    );

    switch (status) {
      case TransferResultStatus.success:
        return TransferResult.success(message: message);
      case TransferResultStatus.cancelled:
        return TransferResult.cancelled(message: message ?? 'Cancelled');
      case TransferResultStatus.paused:
        return TransferResult.paused(message: message ?? 'Paused');
      case TransferResultStatus.failed:
        return TransferResult.failure(
          taxonomyCode: taxonomyCode ?? map['errorType'] as String? ?? 'unknown',
          retryable: retryable,
          message: message ?? 'Transfer failed',
          httpStatus: httpStatus,
          recoveryAction: recoveryAction,
        );
    }
  }

  @override
  String toString() =>
      'TransferResult(status: $status, taxonomyCode: $taxonomyCode, retryable: $retryable, message: $message, httpStatus: $httpStatus)';
}
