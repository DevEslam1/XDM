import 'package:flutter/material.dart';

class TabGroup {
  final String id;
  final String name;
  final Color color;
  final List<String> tabIds;

  const TabGroup({
    required this.id,
    required this.name,
    required this.color,
    required this.tabIds,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color.toARGB32(),
        'tabIds': tabIds,
      };

  factory TabGroup.fromJson(Map<String, dynamic> json) {
    return TabGroup(
      id: json['id'] as String,
      name: json['name'] as String,
      color: Color(json['color'] as int? ?? Colors.blue.toARGB32()),
      tabIds: (json['tabIds'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
    );
  }

  TabGroup copyWith({
    String? id,
    String? name,
    Color? color,
    List<String>? tabIds,
  }) {
    return TabGroup(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      tabIds: tabIds ?? List.from(this.tabIds),
    );
  }
}
