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

  String get domain {
    try {
      var host = Uri.parse(url).host;
      if (host.startsWith('www.')) host = host.substring(4);
      return host.isEmpty ? url : host;
    } catch (e, st) {
      Logger('bookmark').warning('[bookmark] domain parse failed', e, st);
      return url;
    }
  }

  String get initial {
    final source = title.trim().isNotEmpty ? title.trim() : domain;
    return source.isEmpty ? '?' : source[0].toUpperCase();
  }

  Color get accentColor {
    const palette = [
      Color(0xFF3B82F6),
      Color(0xFF8B5CF6),
      Color(0xFF10B981),
      Color(0xFFF59E0B),
      Color(0xFFEF4444),
      Color(0xFF06B6D4),
      Color(0xFFFACC15),
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Bookmark && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}