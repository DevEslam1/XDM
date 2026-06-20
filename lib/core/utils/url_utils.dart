import 'package:dio/dio.dart';
import 'file_utils.dart';

bool isHttpUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

bool isMagnetUrl(String value) {
  final clean = value.trim();
  if (!clean.toLowerCase().startsWith('magnet:')) return false;
  final parsed = parseMagnetUrl(clean);
  final infoHash = parsed['infoHash'];
  if (infoHash == null || infoHash.isEmpty) return false;
  
  // BitTorrent info hash validation:
  // - 40 character hex string (SHA-1)
  // - 32 character base32 string
  // - 64 character hex string (SHA-256 for BitTorrent v2)
  final isHex40 = RegExp(r'^[A-F0-9]{40}$').hasMatch(infoHash);
  final isBase32 = RegExp(r'^[A-Z2-7]{32}$').hasMatch(infoHash);
  final isHex64 = RegExp(r'^[A-F0-9]{64}$').hasMatch(infoHash);
  return isHex40 || isBase32 || isHex64;
}

bool isTorrentFileUrl(String value) {
  final clean = value.trim().toLowerCase();
  return clean.startsWith('file://') || clean.endsWith('.torrent') || clean.contains('.torrent?');
}

bool isValidTransmissionUrl(String value) {
  return isHttpUrl(value) || isMagnetUrl(value) || isTorrentFileUrl(value);
}

Map<String, String> parseMagnetUrl(String magnetUrl) {
  final Map<String, String> result = {};
  final trimmed = magnetUrl.trim();
  if (!trimmed.toLowerCase().startsWith('magnet:')) return result;

  // Try regex extraction first, as it's robust to unescaped query chars
  final xtMatch = RegExp(r'xt=urn:btih:([a-zA-Z0-9]+)', caseSensitive: false).firstMatch(trimmed);
  if (xtMatch != null) {
    result['infoHash'] = xtMatch.group(1)!.toUpperCase();
  }

  final dnMatch = RegExp(r'dn=([^&]+)', caseSensitive: false).firstMatch(trimmed);
  if (dnMatch != null) {
    try {
      result['name'] = Uri.decodeComponent(dnMatch.group(1)!);
    } catch (_) {
      result['name'] = dnMatch.group(1)!;
    }
  }

  // Fallback / supplement via Uri parsing
  try {
    final uri = Uri.parse(trimmed);
    final queryParams = uri.queryParametersAll;

    if (!result.containsKey('infoHash')) {
      final xtList = queryParams['xt'] ?? [];
      for (final xt in xtList) {
        if (xt.startsWith('urn:btih:')) {
          result['infoHash'] = xt.substring('urn:btih:'.length).toUpperCase();
        }
      }
    }

    if (!result.containsKey('name')) {
      final dnList = queryParams['dn'] ?? [];
      if (dnList.isNotEmpty) {
        result['name'] = Uri.decodeComponent(dnList.first);
      }
    }
  } catch (_) {
    // Keep whatever regex was able to parse
  }

  return result;
}

String fileNameFromUrl(String url) {
  final uri = Uri.tryParse(url);
  final fallback = 'download_${DateTime.now().millisecondsSinceEpoch}.bin';
  if (uri == null) return fallback;

  final segments = uri.pathSegments
      .where((segment) => segment.trim().isNotEmpty)
      .toList();
  if (segments.isEmpty) return fallback;
  return safeFileName(Uri.decodeComponent(segments.last));
}

String? fileNameFromContentDisposition(Headers headers) {
  final value = headers.value('content-disposition');
  if (value == null) return null;

  final utf8Match = RegExp(
    "filename\\*=UTF-8''([^;]+)",
    caseSensitive: false,
  ).firstMatch(value);
  if (utf8Match != null) {
    return safeFileName(Uri.decodeComponent(utf8Match.group(1)!));
  }

  final quotedMatch = RegExp(
    'filename="([^"]+)"|filename=([^";\\s]+)',
    caseSensitive: false,
  ).firstMatch(value);
  if (quotedMatch != null) {
    final name = quotedMatch.group(1) ?? quotedMatch.group(2);
    if (name != null) return safeFileName(name.trim());
  }

  return null;
}

String convertIdnToPunycode(String urlStr) {
  try {
    final uri = Uri.parse(urlStr.trim());
    final host = uri.host;
    if (host.isEmpty) return urlStr;

    final parts = host.split('.');
    var isEncoded = false;
    final punyParts = parts.map((part) {
      if (part.runes.any((r) => r > 127)) {
        isEncoded = true;
        return 'xn--${_punycodeEncode(part)}';
      }
      return part;
    }).toList();

    if (!isEncoded) return urlStr;

    final newHost = punyParts.join('.');
    return uri.replace(host: newHost).toString();
  } catch (_) {
    return urlStr;
  }
}

String _punycodeEncode(String input) {
  const int base = 36;
  const int tmin = 1;
  const int tmax = 26;
  const int skew = 38;
  const int damp = 700;
  const int initialBias = 72;
  const int initialN = 128;

  final runes = input.runes.toList();
  final basic = runes.where((r) => r < 128).toList();
  final output = StringBuffer();
  for (final char in basic) {
    output.writeCharCode(char);
  }

  int h = basic.length;
  int b = basic.length;
  if (b > 0) {
    output.write('-');
  }

  int n = initialN;
  int delta = 0;
  int bias = initialBias;

  int adapt(int dVal, int numPoints, bool firstTime) {
    var delta = firstTime ? dVal ~/ damp : dVal ~/ 2;
    delta += delta ~/ numPoints;
    int k = 0;
    while (delta > ((base - tmin) * tmax) ~/ 2) {
      delta ~/= base - tmin;
      k += base;
    }
    return k + (((base - tmin + 1) * delta) ~/ (delta + skew));
  }

  while (h < runes.length) {
    int m = 0x7FFFFFFF;
    for (final char in runes) {
      if (char >= n && char < m) {
        m = char;
      }
    }

    delta += (m - n) * (h + 1);
    if (delta < 0) throw FormatException('Punycode delta overflow');
    n = m;

    for (final char in runes) {
      if (char < n) {
        delta++;
      } else if (char == n) {
        int q = delta;
        int k = base;
        int safety = 0;
        while (true) {
          safety++;
          if (safety > 10000) {
            throw FormatException('Punycode encode infinite loop guard triggered');
          }
          final t = k <= bias
              ? tmin
              : k >= bias + tmax
                  ? tmax
                  : k - bias;
          if (q < t) break;
          final code = t + ((q - t) % (base - t));
          output.writeCharCode(_punycodeDigit(code));
          q = (q - t) ~/ (base - t);
          k += base;
        }
        output.writeCharCode(_punycodeDigit(q));
        bias = adapt(delta, h + 1, h == b);
        delta = 0;
        h++;
      }
    }
    delta++;
    n++;
  }
  return output.toString();
}

int _punycodeDigit(int d) {
  if (d < 26) return d + 97; // a-z
  return d + 22; // 0-9
}
