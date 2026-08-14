sealed class BackendException implements Exception {
  final String message;

  const BackendException(this.message);

  String toUserMessage() => message;

  @override
  String toString() => '$runtimeType: $message';
}

class BackendBadRequestException extends BackendException {
  const BackendBadRequestException(
      [super.message = 'Invalid URL or unsupported video.']);

  @override
  String toUserMessage() => message;
}

class BackendUnauthorizedException extends BackendException {
  const BackendUnauthorizedException(
      [super.message = 'Backend authentication failed. Check your API token.']);

  @override
  String toUserMessage() => message;
}

class BackendNotFoundException extends BackendException {
  const BackendNotFoundException(
      [super.message = 'No streams found for this video.']);

  @override
  String toUserMessage() => message;
}

class BackendRateLimitException extends BackendException {
  final int? retryAfterSeconds;

  const BackendRateLimitException({
    this.retryAfterSeconds,
    String? message,
  }) : super(
          message ??
              (retryAfterSeconds != null
                  ? 'Rate limit reached. Try again in $retryAfterSeconds seconds.'
                  : 'Rate limit reached. Try again later.'),
        );

  @override
  String toUserMessage() => message;
}

class BackendNetworkException extends BackendException {
  const BackendNetworkException(
      [super.message =
          'Cannot reach download backend. Check your connection.']);

  @override
  String toUserMessage() => message;
}

class BackendUnknownException extends BackendException {
  const BackendUnknownException([super.message = 'Unexpected backend error.']);

  @override
  String toUserMessage() => message;
}

class XdmBackendTimeoutException extends BackendException {
  const XdmBackendTimeoutException(
      [super.message = 'The backend request timed out.']);
}

typedef BackendTimeoutException = XdmBackendTimeoutException;
