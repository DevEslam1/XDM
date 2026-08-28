import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../domain/subscription/subscription_status.dart';
import '../logging_service.dart';

/// Response from the Sub Club validation endpoint.
class SubClubValidationResponse {
  final SubscriptionStatus status;
  final String? expiresAt;
  final String? planId;
  final bool isInGracePeriod;
  final Map<String, dynamic> metadata;

  const SubClubValidationResponse({
    required this.status,
    this.expiresAt,
    this.planId,
    this.isInGracePeriod = false,
    this.metadata = const {},
  });

  factory SubClubValidationResponse.fromJson(Map<String, dynamic> json) {
    return SubClubValidationResponse(
      status: _parseStatus(json['status'] as String?),
      expiresAt: json['expires_at'] as String?,
      planId: json['plan_id'] as String?,
      isInGracePeriod: json['in_grace_period'] as bool? ?? false,
      metadata: json['metadata'] as Map<String, dynamic>? ?? {},
    );
  }

  static SubscriptionStatus _parseStatus(String? raw) {
    switch (raw) {
      case 'active':
        return SubscriptionStatus.active;
      case 'trial':
        return SubscriptionStatus.trial;
      case 'expired':
        return SubscriptionStatus.expired;
      case 'cancelled':
        return SubscriptionStatus.cancelled;
      case 'free':
        return SubscriptionStatus.free;
      default:
        return SubscriptionStatus.unknown;
    }
  }

  @override
  String toString() =>
      'SubClubValidationResponse(status=$status, expires=$expiresAt, plan=$planId)';
}

/// HTTP client for Sub Club subscription validation API.
///
/// This client communicates with the Sub Club server to validate receipts,
/// check entitlements, and manage subscription state. All methods are
/// idempotent and handle network errors gracefully.
class SubClubApiClient {
  SubClubApiClient({
    Dio? dio,
    String? baseUrl,
    String? apiKey,
  })  : _dio = dio ?? Dio(),
        _baseUrl = baseUrl ?? _defaultBaseUrl,
        _apiKey = apiKey;

  static const _defaultBaseUrl = 'https://api.sub.club/v1';
  static const _timeout = Duration(seconds: 15);
  static const _maxRetries = 2;

  final Dio _dio;
  final String _baseUrl;
  final String? _apiKey;

  final _log = LoggingService.logger('SubClubApiClient');

  /// Validates a purchase receipt against the Sub Club server.
  Future<SubClubValidationResponse> validateReceipt(String receipt) async {
    return _postWithRetry('/validate', {
      'receipt': receipt,
      'platform':
          defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    });
  }

  /// Restores purchases for the current user on a new device.
  Future<SubClubValidationResponse> restorePurchases({
    required String platform,
    required String accountToken,
  }) async {
    return _postWithRetry('/restore', {
      'platform': platform,
      'account_token': accountToken,
    });
  }

  /// Checks if a specific entitlement is active for the given receipt.
  Future<bool> checkEntitlement({
    required String receipt,
    required String entitlementKey,
  }) async {
    try {
      final response = await _postWithRetry('/entitlements', {
        'receipt': receipt,
        'entitlement': entitlementKey,
      });
      return response.status.isPremium;
    } catch (e, st) {
      _log.warning('Entitlement check failed', e, st);
      return false;
    }
  }

  /// Fetches the current server time for clock-skew validation.
  Future<DateTime?> getServerTime() async {
    try {
      final response = await _dio.get(
        '$_baseUrl/time',
        options: Options(headers: _headers),
      );
      if (response.statusCode == 200) {
        final json = response.data as Map<String, dynamic>;
        return DateTime.parse(json['time'] as String);
      }
      return null;
    } catch (e) {
      _log.fine('Server time fetch failed: $e');
      return null;
    }
  }

  /// Closes the underlying HTTP client.
  void dispose() {
    _dio.close(force: true);
  }

  // ── Private helpers ──

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-Client-Version': '3.0.0',
        if (_apiKey != null) 'Authorization': 'Bearer $_apiKey',
      };

  Future<SubClubValidationResponse> _postWithRetry(
    String path,
    Map<String, dynamic> body,
  ) async {
    int attempt = 0;
    while (true) {
      try {
        final response = await _dio.post(
          '$_baseUrl$path',
          data: body,
          options: Options(
            headers: _headers,
            sendTimeout: _timeout,
            receiveTimeout: _timeout,
          ),
        );

        if (response.statusCode == 200) {
          final json = response.data as Map<String, dynamic>;
          return SubClubValidationResponse.fromJson(json);
        }

        // 4xx errors are not retryable
        if (response.statusCode != null &&
            response.statusCode! >= 400 &&
            response.statusCode! < 500) {
          _log.warning('Sub Club API ${response.statusCode}: ${response.data}');
          return const SubClubValidationResponse(
            status: SubscriptionStatus.unknown,
          );
        }

        // 5xx errors are retryable
        attempt++;
        if (attempt > _maxRetries) {
          _log.warning(
              'Sub Club API failed after $_maxRetries retries: ${response.statusCode}');
          return const SubClubValidationResponse(
            status: SubscriptionStatus.unknown,
          );
        }
        await Future.delayed(Duration(seconds: attempt * 2));
      } on TimeoutException {
        attempt++;
        if (attempt > _maxRetries) {
          _log.warning('Sub Club API timed out after $_maxRetries retries');
          return const SubClubValidationResponse(
            status: SubscriptionStatus.unknown,
          );
        }
        await Future.delayed(Duration(seconds: attempt * 2));
      } on DioException catch (e, st) {
        _log.warning('Sub Club API error', e, st);
        return const SubClubValidationResponse(
          status: SubscriptionStatus.unknown,
        );
      } catch (e, st) {
        _log.warning('Sub Club API error', e, st);
        return const SubClubValidationResponse(
          status: SubscriptionStatus.unknown,
        );
      }
    }
  }
}
