import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:dmx/core/services/xdm_backend_exceptions.dart';
import 'package:flutter_test/flutter_test.dart';

class _Networkish {
  @override
  String toString() => 'network failed';
}

class _Diskish {
  @override
  String toString() => 'disk full';
}

class _Certish {
  @override
  String toString() => 'certificate problem';
}

void main() {
  group('ErrorTaxonomy', () {
    test('classifies DioException cancel correctly', () {
      final dioCancel = DioException(
        requestOptions: RequestOptions(path: 'https://example.com/file.zip'),
        type: DioExceptionType.cancel,
      );
      final result = ErrorTaxonomy.classify(dioCancel);
      expect(result.family, ErrorFamily.cancelled);
      expect(result.recoveryAction, RecoveryAction.ignore);
      expect(result.retryable, false);
    });

    test('classifies disk full / insufficient storage error correctly', () {
      const diskError = InsufficientStorageException();
      final result = ErrorTaxonomy.classify(diskError);
      expect(result.family, ErrorFamily.disk);
      expect(result.severe, true);
      expect(result.recoveryAction, RecoveryAction.showSettings);
    });

    test('classifies integrity error correctly', () {
      const integrityError = DownloadIntegrityException('Checksum mismatch');
      final result = ErrorTaxonomy.classify(integrityError);
      expect(result.family, ErrorFamily.integrity);
      expect(result.recoveryAction, RecoveryAction.restartDownload);
    });

    test('classifies socket exception as network error with delay', () {
      const socketError = SocketException('Failed host lookup');
      final result = ErrorTaxonomy.classify(socketError);
      expect(result.family, ErrorFamily.network);
      expect(result.retryable, true);
      expect(result.recoveryAction, RecoveryAction.retryWithDelay);
    });

    test('classifies 503 HTTP server error as retryable', () {
      final serverError = DioException(
        requestOptions: RequestOptions(path: 'https://example.com'),
        response: Response(
          requestOptions: RequestOptions(path: 'https://example.com'),
          statusCode: 503,
        ),
      );
      final result = ErrorTaxonomy.classify(serverError);
      expect(result.family, ErrorFamily.server);
      expect(result.httpStatus, 503);
      expect(result.retryable, true);
      expect(result.recoveryAction, RecoveryAction.retrySame);
    });

    test('classifies 410 Gone as auth/expired URL requiring refresh', () {
      final goneError = DioException(
        requestOptions: RequestOptions(path: 'https://example.com'),
        response: Response(
          requestOptions: RequestOptions(path: 'https://example.com'),
          statusCode: 410,
        ),
      );
      final result = ErrorTaxonomy.classify(goneError);
      expect(result.family, ErrorFamily.auth);
      expect(result.httpStatus, 410);
      expect(result.recoveryAction, RecoveryAction.refreshUrl);
    });

    test('recoveryActionFor maps every family', () {
      expect(recoveryActionFor(ErrorFamily.network),
          RecoveryAction.retryWithDelay);
      expect(recoveryActionFor(ErrorFamily.timeout),
          RecoveryAction.retryWithDelay);
      expect(recoveryActionFor(ErrorFamily.auth, httpStatus: 410),
          RecoveryAction.refreshUrl);
      expect(recoveryActionFor(ErrorFamily.auth), RecoveryAction.showSettings);
      expect(recoveryActionFor(ErrorFamily.disk), RecoveryAction.showSettings);
      expect(recoveryActionFor(ErrorFamily.integrity),
          RecoveryAction.restartDownload);
      expect(recoveryActionFor(ErrorFamily.server, httpStatus: 429),
          RecoveryAction.retryWithDelay);
      expect(recoveryActionFor(ErrorFamily.server, httpStatus: 503),
          RecoveryAction.retrySame);
      expect(
          recoveryActionFor(ErrorFamily.server), RecoveryAction.retryWithDelay);
      expect(recoveryActionFor(ErrorFamily.cancelled), RecoveryAction.ignore);
      expect(
          recoveryActionFor(ErrorFamily.parse), RecoveryAction.restartDownload);
      expect(recoveryActionFor(ErrorFamily.unknown),
          RecoveryAction.contactSupport);
    });

    test('classifies positional writer space exhaustion as disk', () {
      final result =
          ErrorTaxonomy.classify(const PositionalFileWriterException('ENOSPC'));
      expect(result.family, ErrorFamily.disk);
      expect(result.severe, isTrue);
    });

    test('classifies generic positional writer errors as unknown', () {
      final result = ErrorTaxonomy.classify(
          const PositionalFileWriterException('unexpected io glitch'));
      expect(result.family, ErrorFamily.unknown);
      expect(result.recoveryAction, RecoveryAction.showSettings);
    });

    test('classifies invalid path as disk', () {
      final result = ErrorTaxonomy.classify(const InvalidPathException('bad'));
      expect(result.family, ErrorFamily.disk);
      expect(result.severe, isTrue);
    });

    test('classifies state persistence failure with and without directory', () {
      final withDir = ErrorTaxonomy.classify(
        const StatePersistenceException('cannot write',
            directory: '/downloads'),
      );
      expect(withDir.family, ErrorFamily.disk);
      expect(withDir.message, contains('/downloads'));

      final withoutDir = ErrorTaxonomy.classify(
        const StatePersistenceException('cannot write'),
      );
      expect(withoutDir.message, 'cannot write');
    });

    test('classifies isolate spawn timeout as retryable timeout', () {
      final result =
          ErrorTaxonomy.classify(const IsolateSpawnTimeoutException());
      expect(result.family, ErrorFamily.timeout);
      expect(result.retryable, isTrue);
    });

    test('classifies expired URL as auth requiring refresh', () {
      final result = ErrorTaxonomy.classify(const UrlExpiredException('gone'));
      expect(result.family, ErrorFamily.auth);
      expect(result.recoveryAction, RecoveryAction.refreshUrl);
    });

    test('classifies torrent engine pause as network', () {
      final result = ErrorTaxonomy.classify(
        const TorrentEnginePauseException('paused', url: 'magnet:?x'),
      );
      expect(result.family, ErrorFamily.network);
    });

    test('classifies torrent stall as retryable network', () {
      final result = ErrorTaxonomy.classify(const TorrentStallException());
      expect(result.family, ErrorFamily.network);
      expect(result.retryable, isTrue);
    });

    test('classifies backend exceptions', () {
      expect(ErrorTaxonomy.classify(const XdmBackendTimeoutException()).family,
          ErrorFamily.timeout);
      expect(ErrorTaxonomy.classify(const BackendNetworkException()).family,
          ErrorFamily.network);
      expect(ErrorTaxonomy.classify(const BackendRateLimitException()).family,
          ErrorFamily.server);
      expect(
          ErrorTaxonomy.classify(const BackendUnauthorizedException()).family,
          ErrorFamily.auth);
      expect(ErrorTaxonomy.classify(const BackendUnknownException()).family,
          ErrorFamily.server);
    });

    test('classifies HTTP status codes provided explicitly', () {
      expect(ErrorTaxonomy.classify(Exception('x'), httpStatus: 401).family,
          ErrorFamily.auth);
      expect(ErrorTaxonomy.classify(Exception('x'), httpStatus: 403).family,
          ErrorFamily.auth);
      expect(ErrorTaxonomy.classify(Exception('x'), httpStatus: 410).family,
          ErrorFamily.auth);
      expect(ErrorTaxonomy.classify(Exception('x'), httpStatus: 500).family,
          ErrorFamily.server);
      expect(ErrorTaxonomy.classify(Exception('x'), httpStatus: 408).family,
          ErrorFamily.server);
      expect(ErrorTaxonomy.classify(Exception('x'), httpStatus: 429).family,
          ErrorFamily.server);
      final notFound = ErrorTaxonomy.classify(Exception('x'), httpStatus: 404);
      expect(notFound.family, ErrorFamily.unknown);
      expect(notFound.recoveryAction, RecoveryAction.contactSupport);
    });

    test('classifies TimeoutException as retryable timeout', () {
      final result = ErrorTaxonomy.classify(TimeoutException('timed out'));
      expect(result.family, ErrorFamily.timeout);
      expect(result.retryable, isTrue);
    });

    test('classifies Dio bad certificate as auth refresh', () {
      final result = ErrorTaxonomy.classify(DioException(
        requestOptions: RequestOptions(path: 'https://x'),
        type: DioExceptionType.badCertificate,
      ));
      expect(result.family, ErrorFamily.auth);
      expect(result.recoveryAction, RecoveryAction.refreshUrl);
    });

    test('classifies Dio connection timeouts as timeout', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
      ]) {
        final result = ErrorTaxonomy.classify(DioException(
          requestOptions: RequestOptions(path: 'https://x'),
          type: type,
        ));
        expect(result.family, ErrorFamily.timeout);
      }
    });

    test('classifies Dio connectionError variants', () {
      final tls = ErrorTaxonomy.classify(DioException(
        requestOptions: RequestOptions(path: 'https://x'),
        type: DioExceptionType.connectionError,
        error: const HandshakeException('bad cert'),
      ));
      expect(tls.family, ErrorFamily.auth);

      final socket = ErrorTaxonomy.classify(DioException(
        requestOptions: RequestOptions(path: 'https://x'),
        type: DioExceptionType.connectionError,
        error: const SocketException('refused'),
      ));
      expect(socket.family, ErrorFamily.network);

      final generic = ErrorTaxonomy.classify(DioException(
        requestOptions: RequestOptions(path: 'https://x'),
        type: DioExceptionType.connectionError,
      ));
      expect(generic.family, ErrorFamily.network);
    });

    test('classifies Dio unknown with and without an underlying error', () {
      final withUnderlying = ErrorTaxonomy.classify(DioException(
        requestOptions: RequestOptions(path: 'https://x'),
        type: DioExceptionType.unknown,
        error: StateError('bad state'),
      ));
      expect(withUnderlying.family, ErrorFamily.unknown);

      final noUnderlying = ErrorTaxonomy.classify(DioException(
        requestOptions: RequestOptions(path: 'https://x'),
        type: DioExceptionType.unknown,
      ));
      expect(noUnderlying.family, ErrorFamily.network);
    });

    test('classifies generic TLS-ish errors as auth', () {
      final result = ErrorTaxonomy.classify(_Certish());
      expect(result.family, ErrorFamily.auth);
    });

    test('classifies FileSystemException disk-full and generic', () {
      final full = ErrorTaxonomy.classify(
        const FileSystemException(
          'write failed',
          '/data',
          OSError('No space left on device', 28),
        ),
      );
      expect(full.family, ErrorFamily.disk);

      final generic = ErrorTaxonomy.classify(
        const FileSystemException('io error', '/data', OSError('EIO', 5)),
      );
      expect(generic.family, ErrorFamily.unknown);
      expect(generic.severe, isTrue);
      expect(generic.message, contains('errno'));
    });

    test('classifies FormatException and RangeError as integrity', () {
      expect(ErrorTaxonomy.classify(const FormatException('bad')).family,
          ErrorFamily.integrity);
      expect(ErrorTaxonomy.classify(RangeError('oob')).family,
          ErrorFamily.integrity);
    });

    test('classifies State and Argument errors', () {
      final state = ErrorTaxonomy.classify(StateError('bad state'));
      expect(state.family, ErrorFamily.unknown);
      expect(state.retryable, isTrue);

      final arg = ErrorTaxonomy.classify(ArgumentError('bad arg'));
      expect(arg.family, ErrorFamily.unknown);
      expect(arg.severe, isTrue);

      final assertion = ErrorTaxonomy.classify(AssertionError('boom'));
      expect(assertion.family, ErrorFamily.unknown);
      expect(assertion.retryable, isTrue);
    });

    test('classifies a runtime TypeError', () {
      Object? caught;
      try {
        // ignore: unnecessary_cast, prefer_const_declarations
        final int value = 'not-an-int' as dynamic;
        value.toString();
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<TypeError>());
      final result = ErrorTaxonomy.classify(caught!);
      expect(result.family, ErrorFamily.unknown);
      expect(result.retryable, isTrue);
    });

    test('classifies file-changed-on-server as integrity', () {
      final result = ErrorTaxonomy.classify(FileChangedOnServerException());
      expect(result.family, ErrorFamily.integrity);
      expect(result.recoveryAction, RecoveryAction.restartDownload);
    });

    test('classifies string-heuristic network and disk errors', () {
      expect(ErrorTaxonomy.classify(_Networkish()).family, ErrorFamily.network);
      expect(ErrorTaxonomy.classify(_Diskish()).family, ErrorFamily.disk);
    });

    test('classifies a truly unknown error as contact support', () {
      final result = ErrorTaxonomy.classify(Object());
      expect(result.family, ErrorFamily.unknown);
      expect(result.recoveryAction, RecoveryAction.contactSupport);
    });

    test('ErrorClassification exposes server/network predicates', () {
      final server = ErrorTaxonomy.classify(DioException(
        requestOptions: RequestOptions(path: 'https://x'),
        response: Response(
          requestOptions: RequestOptions(path: 'https://x'),
          statusCode: 502,
        ),
      ));
      expect(server.isServerError, isTrue);
      expect(server.isNetworkError, isFalse);

      final network = ErrorTaxonomy.classify(const SocketException('x'));
      expect(network.isNetworkError, isTrue);
      expect(network.isServerError, isFalse);
    });
  });
}
