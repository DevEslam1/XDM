import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/user_script_manager.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';

class ScriptManagerScreen extends StatefulWidget {
  const ScriptManagerScreen({super.key});

  @override
  State<ScriptManagerScreen> createState() => _ScriptManagerScreenState();
}

class _ScriptManagerScreenState extends State<ScriptManagerScreen> {
  final UserScriptManager _manager = UserScriptManager.instance;

  @override
  void initState() {
    super.initState();
    _manager.load();
  }

  Future<void> _addScript() async {
    final result = await showDialog<_ScriptResult>(
      context: context,
      builder: (_) => const _ScriptEditorDialog(),
    );
    if (result == null) return;
    if (!mounted) return;
    runHaptic(context.read<SettingsProvider>());
    await _manager.add(
      UserScript(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: result.name,
        urlPattern: result.urlPattern,
        code: result.code,
        isCss: result.isCss,
        permissions: result.permissions,
      ),
    );
  }

  Future<void> _editScript(UserScript script) async {
    final result = await showDialog<_ScriptResult>(
      context: context,
      builder: (_) => _ScriptEditorDialog(
        initialName: script.name,
        initialUrlPattern: script.urlPattern,
        initialCode: script.code,
        initialIsCss: script.isCss,
        initialPermissions: script.permissions,
      ),
    );
    if (result == null) return;
    if (!mounted) return;
    runHaptic(context.read<SettingsProvider>());
    await _manager.update(
      script.copyWith(
        name: result.name,
        urlPattern: result.urlPattern,
        code: result.code,
        isCss: result.isCss,
        permissions: result.permissions,
      ),
    );
  }

  Future<void> _delete(UserScript script) async {
    await _manager.remove(script.id);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final isAmoled = settings.isAmoledMode;
    final manager = context.watch<UserScriptManager>();

    return Scaffold(
      backgroundColor: AppTheme.getBackground(isDark, isAmoled: isAmoled),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(L10n.of(context, 'browser_scripts')),
        actions: [
          IconButton(
            icon: Icon(Icons.add, color: accent),
            tooltip: L10n.of(context, 'browser_add_script'),
            onPressed: _addScript,
          ),
        ],
      ),
      body: manager.scripts.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.code_rounded,
                    size: 56,
                    color:
                        isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    L10n.of(context, 'browser_no_scripts'),
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textPrimary
                          : AppTheme.lightTextPrimary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    L10n.of(context, 'browser_no_scripts_desc'),
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textSecondary
                          : AppTheme.lightTextSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: manager.scripts.length,
              separatorBuilder: (context, index) => const SizedBox(height: 6),
              itemBuilder: (context, i) {
                final script = manager.scripts[i];
                return Container(
                  decoration: BoxDecoration(
                    color: isDark
                        ? (isAmoled ? AppTheme.amoledCardBg : AppTheme.glassBg.withValues(alpha: 0.4))
                        : AppTheme.lightGlassBg.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isDark
                          ? (isAmoled ? AppTheme.amoledBorder : AppTheme.glassBorder)
                          : AppTheme.lightGlassBorder,
                      width: 0.6,
                    ),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => _editScript(script),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color:
                                    (script.isCss ? AppTheme.neonGreen : accent)
                                        .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                script.isCss
                                    ? Icons.palette_outlined
                                    : Icons.code,
                                color:
                                    script.isCss ? AppTheme.neonGreen : accent,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    script.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isDark
                                          ? AppTheme.textPrimary
                                          : AppTheme.lightTextPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    script.urlPattern,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isDark
                                          ? AppTheme.textMuted
                                          : AppTheme.lightTextMuted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: script.enabled,
                              activeThumbColor: accent,
                              onChanged: (val) =>
                                  _manager.toggle(script.id, val),
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.delete_outline,
                                size: 16,
                                color: isDark
                                    ? AppTheme.neonRed
                                    : AppTheme.lightNeonRed,
                              ),
                              tooltip: L10n.of(context, 'browser_delete'),
                              onPressed: () => _delete(script),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _ScriptResult {
  final String name;
  final String urlPattern;
  final String code;
  final bool isCss;
  final Set<ScriptPermission> permissions;
  _ScriptResult(this.name, this.urlPattern, this.code, this.isCss, this.permissions);
}

class _ScriptEditorDialog extends StatefulWidget {
  final String initialName;
  final String initialUrlPattern;
  final String initialCode;
  final bool initialIsCss;
  final Set<ScriptPermission> initialPermissions;

  const _ScriptEditorDialog({
    this.initialName = '',
    this.initialUrlPattern = '',
    this.initialCode = '',
    this.initialIsCss = false,
    this.initialPermissions = const {ScriptPermission.domRead, ScriptPermission.domWrite},
  });

  @override
  State<_ScriptEditorDialog> createState() => _ScriptEditorDialogState();
}

class _ScriptEditorDialogState extends State<_ScriptEditorDialog> {
  late final TextEditingController _nameC;
  late final TextEditingController _urlC;
  late final TextEditingController _codeC;
  late bool _isCss;
  late Set<ScriptPermission> _permissions;

  @override
  void initState() {
    super.initState();
    _nameC = TextEditingController(text: widget.initialName);
    _urlC = TextEditingController(text: widget.initialUrlPattern);
    _codeC = TextEditingController(text: widget.initialCode);
    _isCss = widget.initialIsCss;
    _permissions = Set.from(widget.initialPermissions);
  }

  @override
  void dispose() {
    _nameC.dispose();
    _urlC.dispose();
    _codeC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    return AlertDialog(
      backgroundColor:
          (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(
        alpha: 0.95,
      ),
      title: Text(
        widget.initialName.isEmpty
            ? L10n.of(context, 'browser_add_script')
            : L10n.of(context, 'browser_edit_script'),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameC,
              decoration: InputDecoration(
                labelText: L10n.of(context, 'browser_script_name'),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlC,
              decoration: InputDecoration(
                labelText: L10n.of(context, 'browser_script_url_pattern'),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  L10n.of(context, 'browser_script_type'),
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark
                        ? AppTheme.textSecondary
                        : AppTheme.lightTextSecondary,
                  ),
                ),
                const SizedBox(width: 12),
                ChoiceChip(
                  label: Text(L10n.of(context, 'browser_script_js')),
                  selected: !_isCss,
                  onSelected: (_) => setState(() => _isCss = false),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text(L10n.of(context, 'browser_script_css')),
                  selected: _isCss,
                  onSelected: (_) => setState(() => _isCss = true),
                ),
              ],
            ),
            if (!_isCss) ...[
              const SizedBox(height: 12),
              Text(
                'Script Permissions',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: ScriptPermission.values.map((perm) {
                  final selected = _permissions.contains(perm);
                  return FilterChip(
                    label: Text(perm.name, style: const TextStyle(fontSize: 11)),
                    selected: selected,
                    onSelected: (val) {
                      setState(() {
                        if (val) {
                          _permissions.add(perm);
                        } else {
                          _permissions.remove(perm);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _codeC,
              maxLines: 8,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                labelText: L10n.of(context, 'browser_script_code'),
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(L10n.of(context, 'browser_cancel_uppercase')),
        ),
        FilledButton(
          onPressed: () {
            final name = _nameC.text.trim();
            final pattern = _urlC.text.trim();
            final code = _codeC.text.trim();
            if (name.isEmpty || pattern.isEmpty || code.isEmpty) return;
            Navigator.pop(
              context,
              _ScriptResult(name, pattern, code, _isCss, _permissions),
            );
          },
          child: Text(L10n.of(context, 'browser_save_btn')),
        ),
      ],
    );
  }
}
