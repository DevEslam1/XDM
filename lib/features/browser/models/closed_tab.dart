class ClosedTab {
  final String url;
  final String title;
  final bool isIncognito;
  final int closedAt;

  const ClosedTab({
    required this.url,
    required this.title,
    this.isIncognito = false,
    required this.closedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'url': url,
      'title': title,
      'isIncognito': isIncognito,
      'closedAt': closedAt,
    };
  }

  factory ClosedTab.fromMap(Map<String, dynamic> map) {
    return ClosedTab(
      url: map['url'] as String? ?? '',
      title: map['title'] as String? ?? '',
      isIncognito: map['isIncognito'] as bool? ?? false,
      closedAt: (map['closedAt'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => toMap();
  factory ClosedTab.fromJson(Map<String, dynamic> json) =>
      ClosedTab.fromMap(json);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClosedTab &&
          runtimeType == other.runtimeType &&
          url == other.url &&
          title == other.title &&
          isIncognito == other.isIncognito &&
          closedAt == other.closedAt;

  @override
  int get hashCode => Object.hash(url, title, isIncognito, closedAt);
}
