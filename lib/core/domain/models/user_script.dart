enum ScriptPermission {
  domRead,
  domWrite,
  network,
  storage,
  cookies,
}

class UserScript {
  final String id;
  final String name;
  final String urlPattern;
  final String code;
  final bool isCss;
  final bool enabled;
  final Set<ScriptPermission> permissions;

  const UserScript({
    required this.id,
    required this.name,
    required this.urlPattern,
    required this.code,
    this.isCss = false,
    this.enabled = true,
    this.permissions = const {
      ScriptPermission.domRead,
      ScriptPermission.domWrite,
    },
  });

  UserScript copyWith({
    String? name,
    String? urlPattern,
    String? code,
    bool? isCss,
    bool? enabled,
    Set<ScriptPermission>? permissions,
  }) =>
      UserScript(
        id: id,
        name: name ?? this.name,
        urlPattern: urlPattern ?? this.urlPattern,
        code: code ?? this.code,
        isCss: isCss ?? this.isCss,
        enabled: enabled ?? this.enabled,
        permissions: permissions ?? this.permissions,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'urlPattern': urlPattern,
        'code': code,
        'isCss': isCss,
        'enabled': enabled,
        'permissions': permissions.map((e) => e.name).toList(),
      };

  factory UserScript.fromJson(Map<String, dynamic> json) {
    final List<dynamic>? permsJson = json['permissions'] as List<dynamic>?;
    final Set<ScriptPermission> perms = permsJson != null
        ? permsJson
            .map((e) => ScriptPermission.values.firstWhere(
                  (val) => val.name == e,
                  orElse: () => ScriptPermission.domRead,
                ))
            .toSet()
        : {ScriptPermission.domRead, ScriptPermission.domWrite};

    return UserScript(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      urlPattern: json['urlPattern'] as String? ?? '',
      code: json['code'] as String? ?? '',
      isCss: json['isCss'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? true,
      permissions: perms,
    );
  }
}
