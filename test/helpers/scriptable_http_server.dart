import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Reusable, scriptable local HTTP server for download engine testing.
class ScriptableHttpServer {
  HttpServer? _server;
  Uint8List _payload = Uint8List(0);
  String _etag = '"v1"';
  String _lastModified = 'Wed, 21 Oct 2025 07:28:00 GMT';
  final bool _supportRanges = true;
  bool _ignoreRanges = false;
  bool _return416 = false;
  int? _dropAfterBytes;
  List<int> _redirectChain = [];
  String? _redirectFinalPath;
  int _redirectIndex = 0;
  Duration _byteDelay = Duration.zero;
  final int _chunkSize = 16 * 1024; // 16KB

  final List<CapturedHttpRequest> capturedRequests = [];

  int get port => _server?.port ?? 0;
  String get baseUrl => 'http://127.0.0.1:$port';
  String urlFor(String path) =>
      '$baseUrl${path.startsWith('/') ? path : '/$path'}';

  Uint8List get payload => _payload;
  String get etag => _etag;

  /// Start server on loopback port
  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest);
  }

  /// Stop and close server
  Future<void> stop() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  /// Set the payload to serve
  void setPayload(Uint8List bytes,
      {String etag = '"v1"', String? lastModified}) {
    _payload = bytes;
    _etag = etag;
    if (lastModified != null) _lastModified = lastModified;
  }

  /// Toggle whether Range headers are honored (206) or ignored (200 full body)
  void setIgnoreRanges(bool ignore) {
    _ignoreRanges = ignore;
  }

  /// Force 416 Range Not Satisfiable
  void setReturn416(bool return416) {
    _return416 = return416;
  }

  /// Update ETag (e.g. to simulate server file change)
  void setEtag(String newEtag) {
    _etag = newEtag;
  }

  /// Simulate abrupt connection drop after sending [bytes]
  void setDropConnectionAfterBytes(int? bytes) {
    _dropAfterBytes = bytes;
  }

  /// Configure redirect chain before serving file
  void setRedirectChain(List<int> statusCodes, String finalPath) {
    _redirectChain = List.from(statusCodes);
    _redirectFinalPath = finalPath;
    _redirectIndex = 0;
  }

  /// Reset all scriptable overrides
  void reset() {
    _ignoreRanges = false;
    _return416 = false;
    _dropAfterBytes = null;
    _redirectChain.clear();
    _redirectFinalPath = null;
    _redirectIndex = 0;
    _byteDelay = Duration.zero;
    capturedRequests.clear();
  }

  void _handleRequest(HttpRequest request) async {
    final rangeHeader = request.headers.value('range');
    final ifRangeHeader = request.headers.value('if-range');

    capturedRequests.add(CapturedHttpRequest(
      method: request.method,
      uri: request.uri,
      headers: Map.fromEntries(
        request.headers
            .toString()
            .split('\n')
            .where((s) => s.contains(':'))
            .map((s) {
          final idx = s.indexOf(':');
          return MapEntry(s.substring(0, idx).trim().toLowerCase(),
              s.substring(idx + 1).trim());
        }),
      ),
      rangeHeader: rangeHeader,
      ifRangeHeader: ifRangeHeader,
    ));

    // Handle Redirect Chains
    if (_redirectIndex < _redirectChain.length) {
      final statusCode = _redirectChain[_redirectIndex++];
      final isLastRedirect = _redirectIndex >= _redirectChain.length;
      final targetPath = isLastRedirect
          ? (_redirectFinalPath ?? '/file.bin')
          : '/redirect_$_redirectIndex';
      request.response.statusCode = statusCode;
      request.response.headers
          .set(HttpHeaders.locationHeader, urlFor(targetPath));
      await request.response.close();
      return;
    }

    // Handle 416
    if (_return416) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers
          .set('Content-Range', 'bytes */${_payload.length}');
      await request.response.close();
      return;
    }

    // Handle If-Range / ETag mismatch
    var ifRangeMismatch = false;
    if (ifRangeHeader != null && ifRangeHeader != _etag) {
      ifRangeMismatch = true; // Server file changed, return full 200 OK
    }

    // Handle Range Requests
    if (_supportRanges &&
        !_ignoreRanges &&
        !ifRangeMismatch &&
        rangeHeader != null &&
        rangeHeader.startsWith('bytes=')) {
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      if (match != null) {
        final start = int.parse(match.group(1)!);
        final endStr = match.group(2);
        final end = (endStr != null && endStr.isNotEmpty)
            ? int.parse(endStr)
            : _payload.length - 1;

        if (start >= _payload.length) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          request.response.headers
              .set('Content-Range', 'bytes */${_payload.length}');
          await request.response.close();
          return;
        }

        final slice = _payload.sublist(start, end + 1);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set('ETag', _etag);
        request.response.headers.set('Last-Modified', _lastModified);
        request.response.headers.set('Accept-Ranges', 'bytes');
        request.response.headers
            .set('Content-Range', 'bytes $start-$end/${_payload.length}');
        request.response.headers.set('Content-Length', slice.length.toString());

        await _sendBodyWithFaultInjection(request, slice);
        return;
      }
    }

    // Default 200 OK (Full body)
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.set('ETag', _etag);
    request.response.headers.set('Last-Modified', _lastModified);
    request.response.headers
        .set('Accept-Ranges', _supportRanges ? 'bytes' : 'none');
    request.response.headers.set('Content-Length', _payload.length.toString());

    await _sendBodyWithFaultInjection(request, _payload);
  }

  Future<void> _sendBodyWithFaultInjection(
      HttpRequest request, Uint8List data) async {
    var sent = 0;
    while (sent < data.length) {
      final chunkEnd =
          (sent + _chunkSize < data.length) ? sent + _chunkSize : data.length;
      final chunk = data.sublist(sent, chunkEnd);

      if (_dropAfterBytes != null &&
          (sent + chunk.length) >= _dropAfterBytes!) {
        // Send partial chunk up to drop threshold then simulate socket reset
        final sendable = _dropAfterBytes! - sent;
        if (sendable > 0) {
          request.response.add(chunk.sublist(0, sendable));
          await request.response.flush().catchError((_) {});
        }
        _dropAfterBytes = null; // Drop only once
        request.response
            .addError(const SocketException('Connection reset by peer'));
        try {
          await request.response.close();
        } catch (_) {}
        return;
      }

      request.response.add(chunk);
      sent += chunk.length;
      if (_byteDelay > Duration.zero) {
        await Future.delayed(_byteDelay);
      }
    }
    await request.response.close();
  }
}

class CapturedHttpRequest {
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String? rangeHeader;
  final String? ifRangeHeader;

  const CapturedHttpRequest({
    required this.method,
    required this.uri,
    required this.headers,
    this.rangeHeader,
    this.ifRangeHeader,
  });
}
