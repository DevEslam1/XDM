import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// In-memory [HttpOverrides] that answers every request with [body] and a
/// `application/json` content type. Lets Dio be exercised in widget tests
/// without opening a real socket.
class FakeHttpOverrides extends HttpOverrides {
  FakeHttpOverrides(
    this.body, {
    this.statusCode = 200,
    this.delay = Duration.zero,
  });

  final List<int> body;
  final int statusCode;
  final Duration delay;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(body, statusCode, delay);
}

class _FakeHeaders implements HttpHeaders {
  _FakeHeaders([Map<String, List<String>>? initial]) {
    if (initial != null) _map.addAll(initial);
  }

  final Map<String, List<String>> _map = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _map[name.toLowerCase()] = ['$value'];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    (_map[name.toLowerCase()] ??= []).add('$value');
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _map.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this._body, this._statusCode);

  final List<int> _body;
  final int _statusCode;

  @override
  final HttpHeaders headers = _FakeHeaders({
    'content-type': ['application/json']
  });

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([_body]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  int get statusCode => _statusCode;
  @override
  String get reasonPhrase => 'OK';
  @override
  int get contentLength => _body.length;
  @override
  bool get persistentConnection => false;
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  List<Cookie> get cookies => const [];
  @override
  X509Certificate? get certificate => null;
  @override
  HttpConnectionInfo? get connectionInfo => null;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this._response);

  final _FakeHttpClientResponse _response;

  @override
  final HttpHeaders headers = _FakeHeaders();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;
  @override
  bool bufferOutput = true;
  @override
  int contentLength = -1;
  @override
  Encoding encoding = utf8;

  @override
  Future<HttpClientResponse> close() async => _response;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();
  @override
  void add(List<int> data) {}
  @override
  Future<HttpClientResponse> get done async => _response;
  @override
  Future<void> flush() async {}
  @override
  void write(Object? object) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._body, this._statusCode, this._delay);

  final List<int> _body;
  final int _statusCode;
  final Duration _delay;

  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  bool autoUncompress = true;
  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (_delay > Duration.zero) await Future<void>.delayed(_delay);
    return _FakeHttpClientRequest(_FakeHttpClientResponse(_body, _statusCode));
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
