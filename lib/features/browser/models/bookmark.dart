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

  Bookmark copyWith({
    String? title,
    String? url,
    String? folder,
  }) {
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
      id: map['id'] as String,
      title: map['title'] as String? ?? '',
      url: map['url'] as String? ?? '',
      folder: map['folder'] as String?,
      createdAt: DateTime.tryParse(map['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
