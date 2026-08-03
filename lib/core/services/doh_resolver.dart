import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

/// RFC 8484 DNS-over-HTTPS (DoH) resolver with TTL caching.
class DohResolver {
  static final _log = Logger('DohResolver');
  DohResolver._();
  static final DohResolver instance = DohResolver._();

  final Map<String, _CacheEntry> _cache = {};

  /// Resolves [hostname] to an IPv4 address using the DoH [provider].
  /// Returns null on failure or if no A record is found.
  Future<String?> resolve(String hostname, String provider) async {
    if (hostname.isEmpty || provider.isEmpty) return null;
    
    // 1. Check in-memory cache
    final now = DateTime.now();
    final cached = _cache[hostname];
    if (cached != null && cached.expiry.isAfter(now)) {
      return cached.ip;
    }

    // 2. Execute DoH query
    try {
      // Use HttpOverrides.runWithHttpOverrides to bypass global overrides and avoid recursion
      return await HttpOverrides.runWithHttpOverrides<Future<String?>>(() async {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 3);
        
        try {
          final query = _createDnsQuery(hostname);
          final uri = Uri.parse('https://$provider/dns-query');
          
          final request = await client.postUrl(uri);
          request.headers.set('Content-Type', 'application/dns-message');
          request.headers.set('Accept', 'application/dns-message');
          request.add(query);
          
          final response = await request.close();
          if (response.statusCode == 200) {
            final body = await response.fold<List<int>>([], (p, e) => p..addAll(e));
            final result = _parseDnsResponse(Uint8List.fromList(body));
            
            if (result != null) {
              // Cache result (fixed 5 min TTL for simplicity, or parse from response)
              _cache[hostname] = _CacheEntry(
                result.ip, 
                now.add(Duration(seconds: result.ttl > 0 ? result.ttl : 300)),
              );
              return result.ip;
            }
          }
        } finally {
          client.close();
        }
        return null;
      }, _InternalHttpOverrides());
    } catch (e) {
      _log.fine('[DohResolver] Resolution failed for $hostname: $e');
      return null;
    }
  }

  @visibleForTesting
  Uint8List createDnsQuery(String hostname) => _createDnsQuery(hostname);

  @visibleForTesting
  ({String ip, int ttl})? parseDnsResponse(Uint8List data) =>
      _parseDnsResponse(data);

  Uint8List _createDnsQuery(String hostname) {
    final builder = BytesBuilder();
    // Header (12 bytes)
    builder.add([0x00, 0x00]); // ID: 0
    builder.add([0x01, 0x00]); // Flags: RD=1
    builder.add([0x00, 0x01]); // QDCOUNT: 1
    builder.add([0x00, 0x00]); // ANCOUNT: 0
    builder.add([0x00, 0x00]); // NSCOUNT: 0
    builder.add([0x00, 0x00]); // ARCOUNT: 0

    // Question
    for (final label in hostname.split('.')) {
      if (label.isEmpty) continue;
      builder.addByte(label.length);
      builder.add(utf8.encode(label));
    }
    builder.addByte(0); // Root label
    builder.add([0x00, 0x01]); // QTYPE: A (1)
    builder.add([0x00, 0x01]); // QCLASS: IN (1)
    
    return builder.toBytes();
  }

  ({String ip, int ttl})? _parseDnsResponse(Uint8List data) {
    try {
      if (data.length < 12) return null;
      final ancount = (data[6] << 8) | data[7];
      if (ancount == 0) return null;

      var offset = 12;
      // Skip Question section
      while (offset < data.length && data[offset] != 0) {
        offset += data[offset] + 1;
      }
      offset += 5; // Null byte + QTYPE(2) + QCLASS(2)

      // Parse Answers
      for (var i = 0; i < ancount; i++) {
        if (offset + 10 > data.length) break;
        
        // Handle Name pointer (0xC0XX) or literal
        if ((data[offset] & 0xC0) == 0xC0) {
          offset += 2;
        } else {
          while (offset < data.length && data[offset] != 0) {
            offset += data[offset] + 1;
          }
          offset += 1;
        }

        if (offset + 10 > data.length) break;
        final type = (data[offset] << 8) | data[offset + 1];
        final ttl = (data[offset + 4] << 24) | (data[offset + 5] << 16) | 
                    (data[offset + 6] << 8) | data[offset + 7];
        final rdlen = (data[offset + 8] << 8) | data[offset + 9];
        offset += 10;

        if (type == 1 && rdlen == 4 && offset + 4 <= data.length) { // TYPE A
          final ip = '${data[offset]}.${data[offset + 1]}.${data[offset + 2]}.${data[offset + 3]}';
          return (ip: ip, ttl: ttl);
        }
        offset += rdlen;
      }
    } catch (e) {
      _log.warning('[DohResolver] Parse error: $e');
    }
    return null;
  }
}

class _InternalHttpOverrides extends HttpOverrides {}

class _CacheEntry {
  final String ip;
  final DateTime expiry;
  _CacheEntry(this.ip, this.expiry);
}
