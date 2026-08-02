import 'dart:ui';
import 'package:logging/logging.dart';

class Bookmark {
  final String id;
  final String title;
  final String url;
  final String? folder;
  final DateTime createdAt;

  Bookmark({
    required this.id,
    required this.title,
    required this.url,
    this.folder,
    required this.createdAt,
  });

  /// Hostname stripped of `www.` — used for compact displays.
  String get domain {
    try {
      var host = Uri.parse(url).host;
      if (host.startsWith('www.')) host = host.substring(4);
      return host.isEmpty ? url : host;
    } catch (e, st) {
      Logger('bookmark').warning('[bookmark] operation failed', e, st);
      return url;
    }
  }

  /// First glyph for the avatar tile.
  String get initial {
    final source = title.trim().isNotEmpty ? title.trim() : domain;
    return source.isEmpty ? '?' : source[0].toUpperCase();
  }

  /// Deterministic accent hue derived from the domain, so every bookmark
  /// gets its own stable identity color.
  Color get accentColor {
    const palette = [
      Color(0xFF3B82F6), // blue
      Color(0xFF8B5CF6), // violet
      Color(0xFF10B981), // green
      Color(0xFFF59E0B), // amber
      Color(0xFFEF4444), // red
      Color(0xFF06B6D4), // cyan
      Color(0xFFFACC15), // yellow
    ];
    return palette[domain.hashCode.abs() % palette.length];
  }

  Bookmark copyWith({String? title, String? url, String? folder}) {
    return Bookmark(
      id: id,
      title: title ?? this.title,
      url: url ?? this.url,
      folder: folder ?? this.folder,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'url': url,
      'folder': folder,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory Bookmark.fromMap(Map<String, dynamic> map) {
    return Bookmark(
      id: map['id'] as String? ?? '',
      title: map['title'] as String? ?? '',
      url: map['url'] as String? ?? '',
      folder: map['folder'] as String?,
      createdAt: parseTimestamp(map['createdAt']),
    );
  }

  /// FIX(4): accepts INTEGER ms-epoch (current DB format) and legacy ISO
  /// strings so previously-serialized data keeps parsing.
  static DateTime parseTimestamp(dynamic value) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value) ?? DateTime.now();
    }
    return DateTime.now();
  }
}