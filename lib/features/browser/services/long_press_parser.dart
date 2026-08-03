import 'dart:convert';
import 'package:logging/logging.dart';

/// Parsed payload of a long-press / context-menu message from the webview.
class LongPressPayload {
  final String url;
  final String type;
  final String text;

  const LongPressPayload({
    required this.url,
    required this.type,
    this.text = '',
  });

  /// Tolerantly decodes the JSON string posted by the XDM_LongPress channel.
  /// Returns null when the payload is missing or has no usable URL.
  static LongPressPayload? tryParse(String raw) {
    if (raw.isEmpty) return null;
    try {
      final map = _decode(raw);
      if (map == null) return null;
      final url = (map['url'] as String?)?.trim() ?? '';
      if (url.isEmpty) return null;
      return LongPressPayload(
        url: url,
        type: (map['type'] as String?)?.trim().toLowerCase() ?? 'link',
        text: (map['text'] as String?) ?? '',
      );
    } catch (e, st) {
      Logger('long_press_parser')
          .warning('[long_press_parser] operation failed', e, st);
      return null;
    }
  }

  static Map<String, dynamic>? _decode(String raw) {
    if (raw.startsWith('{') || raw.startsWith('[')) {
      final decoded = _jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    }
    return null;
  }

  static Object? _jsonDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (e, st) {
      Logger('long_press_parser')
          .warning('[long_press_parser] operation failed', e, st);
      return null;
    }
  }
}

/// A downloadable media source discovered on a page (quality, stream, etc.).
class MediaSourceItem {
  final String label;
  final String url;
  final String type;

  const MediaSourceItem({
    required this.label,
    required this.url,
    required this.type,
  });

  factory MediaSourceItem.fromMap(Map<String, dynamic> map) => MediaSourceItem(
        label: (map['label'] as String?) ?? '',
        url: (map['src'] as String?) ?? (map['url'] as String?) ?? '',
        type: (map['type'] as String?) ?? 'video',
      );
}

/// Picks the sources worth offering for a long-pressed target. The target URL
/// itself is always included first; other discovered sources are included when
/// they share the same media type or the same base URL (i.e. alternative
/// qualities of the same media).
List<MediaSourceItem> filterSourcesForTarget(
  List<MediaSourceItem> sources,
  String targetUrl,
  String type,
) {
  final result = <MediaSourceItem>[];
  final seen = <String>{};

  void add(MediaSourceItem item) {
    if (item.url.isEmpty) return;
    final normalized = item.url.trim();
    if (seen.add(normalized)) {
      result.add(MediaSourceItem(
        label: item.label.isEmpty ? _defaultLabel(type) : item.label,
        url: normalized,
        type: item.type,
      ));
    }
  }

  add(MediaSourceItem(label: _defaultLabel(type), url: targetUrl, type: type));

  final base = _baseUrl(targetUrl);
  final targetHost = _host(targetUrl);
  for (final source in sources) {
    final sameType = source.type == type;
    final sameHost = targetHost.isNotEmpty && _host(source.url) == targetHost;
    final sameBase = base.isNotEmpty && _baseUrl(source.url) == base;
    // Only alternative versions of the same media: same type on the same host
    // (e.g. quality variants), or a matching base path.
    if (sameType && (sameHost || sameBase)) {
      add(source);
    }
  }
  return result;
}

String _defaultLabel(String type) {
  switch (type) {
    case 'video':
      return 'Direct video';
    case 'audio':
      return 'Direct audio';
    case 'image':
      return 'Direct image';
    default:
      return 'Direct link';
  }
}

String _host(String url) {
  try {
    return Uri.parse(url).host.toLowerCase();
  } catch (e, st) {
    Logger('long_press_parser')
        .warning('[long_press_parser] operation failed', e, st);
    return '';
  }
}

String _baseUrl(String url) {
  try {
    final uri = Uri.parse(url);
    if (!uri.hasScheme) return '';
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return '';
    final path = uri.path;
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    // Compare only the host + first path segment so quality variants of the
    // same media (e.g. /video/720p.mp4 vs /video/1080p.mp4) are grouped.
    return '${uri.scheme}://$host${segments.isEmpty ? '' : '/${segments.first}'}';
  } catch (e, st) {
    Logger('long_press_parser')
        .warning('[long_press_parser] operation failed', e, st);
    return '';
  }
}
