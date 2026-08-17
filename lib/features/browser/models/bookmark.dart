import 'dart:ui';
import 'package:dmx/core/app_theme.dart';
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
    const palette = AppTheme.bookmarkPalette;
    return palette[domain.hashCode.abs() % palette.length];
  }

  Bookmark copyWith({
    String? title,
    String? url,
    String? folder,
    bool clearFolder = false,
  }) {
    return Bookmark(
      id: id,
      title: title ?? this.title,
      url: url ?? this.url,
      folder: clearFolder ? null : (folder ?? this.folder),
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

  Map<String, dynamic> toJson() => toMap();

  factory Bookmark.fromMap(Map<String, dynamic> map) {
    return Bookmark(
      id: map['id'] as String? ?? '',
      title: map['title'] as String? ?? '',
      url: map['url'] as String? ?? '',
      folder: map['folder'] as String?,
      createdAt: parseTimestamp(map['createdAt']),
    );
  }

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark.fromMap(json);

  static DateTime parseTimestamp(dynamic value) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    if (value is String && value.isNotEmpty) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed;
      final asInt = int.tryParse(value);
      if (asInt != null) return DateTime.fromMillisecondsSinceEpoch(asInt);
    }
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Bookmark && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
