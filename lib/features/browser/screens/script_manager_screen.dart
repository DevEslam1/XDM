import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/user_script_manager.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/widgets/section_header.dart';
import '../../settings/provider/settings_provider.dart';

class ScriptManagerScreen extends StatefulWidget {
  const ScriptManagerScreen({super.key});

  @override
  State<ScriptManagerScreen> createState() => _ScriptManagerScreenState();
}

class _ScriptManagerScreenState extends State<ScriptManagerScreen>
    with HapticHelper {
  final UserScriptManager _manager = UserScriptManager.instance;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onManagerChanged);
    _manager.load();
    _searchController.addListener(() {
      if (mounted) {
        setState(() {
          _searchQuery = _searchController.text.trim().toLowerCase();
        });
      }
    });
  }

  void _onManagerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerChanged);
    _searchController.dispose();
    super.dispose();
  }

  List<UserScript> get _filteredScripts {
    if (_searchQuery.isEmpty) return _manager.scripts;
    return _manager.scripts.where((s) {
      return s.name.toLowerCase().contains(_searchQuery) ||
          s.urlPattern.toLowerCase().contains(_searchQuery);
    }).toList();
  }

  Future<void> _addScript() async {
    final result = await showDialog<_ScriptResult>(
      context: context,
      builder: (_) => const _ScriptEditorDialog(),
    );
    if (result == null) return;
    if (!mounted) return;
    lightPulse(context.read<SettingsProvider>());
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
    lightPulse(context.read<SettingsProvider>());
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
    final confirmed = await DmxConfirmDialog.show(
      context,
      title: '${L10n.of(context, 'delete_btn')} Script',
      message: 'Are you sure you want to delete "${script.name}"?',
      isDestructive: true,
    );
    if (confirmed == true && mounted) {
      await _manager.remove(script.id);
    }
  }

  Future<void> _toggleScript(UserScript script, bool val) async {
    if (mounted) lightPulse(context.read<SettingsProvider>());
    await _manager.toggle(script.id, val);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final isAmoled = settings.isAmoledMode;
    final manager = _manager;
    final isRtl = L10n.isRtl(context);

    return Scaffold(
      backgroundColor: AppTheme.getBackground(isDark, isAmoled: isAmoled),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          L10n.of(context, 'browser_scripts'),
          style: TextStyle(
            color: isDark ? Colors.white : Colors.black87,
            fontSize: 18,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.2,
          ),
        ),
        centerTitle: false,
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'script_manager_fab',
        onPressed: _addScript,
        backgroundColor: accent,
        foregroundColor: Colors.black,
        elevation: 4,
        icon: const Icon(Icons.add_rounded, size: 22),
        label: Text(
          isRtl ? 'سكربت جديد' : 'New Script',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            letterSpacing: 0.3,
          ),
        ),
      ),
      body: !manager.isLoaded
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      color: accent,
                      strokeWidth: 2.5,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    isRtl ? 'جاري التحميل...' : 'Loading scripts...',
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
          : manager.scripts.isEmpty
              ? EmptyState(
                  icon: Icons.code_rounded,
                  title: L10n.of(context, 'browser_no_scripts'),
                  subtitle: L10n.of(context, 'browser_no_scripts_desc'),
                  actionLabel: isRtl ? 'إضافة سكربت' : 'Add Script',
                  onAction: _addScript,
                  accentColor: accent,
                  isDark: isDark,
                )
              : CustomScrollView(
                  slivers: [
                    // Search bar
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            hintText: isRtl
                                ? 'بحث في السكربتات...'
                                : 'Search scripts...',
                            hintStyle: TextStyle(
                              color: isDark
                                  ? AppTheme.textMuted
                                  : AppTheme.lightTextMuted,
                              fontSize: 13,
                            ),
                            prefixIcon:
                                Icon(Icons.search_rounded, size: 20, color: accent),
                            suffixIcon: _searchQuery.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear_rounded,
                                        size: 18),
                                    onPressed: () => _searchController.clear(),
                                  )
                                : null,
                            filled: true,
                            fillColor: isDark
                                ? (isAmoled
                                    ? AppTheme.amoledCardBg
                                    : AppTheme.surface)
                                : AppTheme.lightSurface,
                            contentPadding: const EdgeInsets.symmetric(
                                vertical: 10, horizontal: 16),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide(
                                color: accent.withValues(alpha: 0.15),
                                width: 0.8,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide(
                                color: accent.withValues(alpha: 0.5),
                                width: 1.2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    // Stats header
                    if (manager.scripts.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              _StatChip(
                                label: isRtl
                                    ? '${manager.scripts.length} سكربت'
                                    : '${manager.scripts.length} scripts',
                                icon: Icons.code_rounded,
                                color: accent,
                                isDark: isDark,
                              ),
                              const SizedBox(width: 8),
                              _StatChip(
                                label:
                                    '${manager.scripts.where((s) => s.enabled).length} ${isRtl ? "نشط" : "active"}',
                                icon: Icons.check_circle_outline_rounded,
                                color: isDark
                                    ? AppTheme.neonGreen
                                    : AppTheme.lightNeonGreen,
                                isDark: isDark,
                              ),
                            ],
                          ),
                        ),
                      ),

                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                      sliver: _filteredScripts.isEmpty
                          ? SliverFillRemaining(
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.search_off_rounded,
                                        size: 48,
                                        color: (isDark
                                                ? AppTheme.textMuted
                                                : AppTheme.lightTextMuted)
                                            .withValues(alpha: 0.5),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        isRtl
                                            ? 'لا توجد نتائج مطابقة'
                                            : 'No matching scripts found',
                                        style: TextStyle(
                                          color: isDark
                                              ? AppTheme.textSecondary
                                              : AppTheme.lightTextSecondary,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                          : SliverList.separated(
                              itemCount: _filteredScripts.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, i) {
                                final script = _filteredScripts[i];
                                return _ScriptCard(
                                  script: script,
                                  isDark: isDark,
                                  isAmoled: isAmoled,
                                  accent: accent,
                                  onEdit: () => _editScript(script),
                                  onDelete: () => _delete(script),
                                  onToggle: (val) =>
                                      _toggleScript(script, val),
                                );
                              },
                            ),
                    ),
                  ],
                ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool isDark;

  const _StatChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: color.withValues(alpha: 0.2),
          width: 0.7,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              fontFamily: 'Space Grotesk',
            ),
          ),
        ],
      ),
    );
  }
}

class _ScriptCard extends StatelessWidget {
  final UserScript script;
  final bool isDark;
  final bool isAmoled;
  final Color accent;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  const _ScriptCard({
    required this.script,
    required this.isDark,
    required this.isAmoled,
    required this.accent,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final cardColor = script.isCss
        ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
        : accent;
    final textPrimary =
        isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final textMuted = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? (isAmoled
                ? AppTheme.amoledCardBg
                : AppTheme.glassBg.withValues(alpha: 0.4))
            : AppTheme.lightGlassBg.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: script.enabled
              ? cardColor.withValues(alpha: 0.4)
              : (isDark
                  ? (isAmoled ? AppTheme.amoledBorder : AppTheme.glassBorder)
                  : AppTheme.lightGlassBorder),
          width: script.enabled ? 1.0 : 0.6,
        ),
        boxShadow: script.enabled
            ? [
                BoxShadow(
                  color: cardColor.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onEdit,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: cardColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: cardColor.withValues(alpha: 0.2),
                      width: 0.7,
                    ),
                  ),
                  child: Icon(
                    script.isCss ? Icons.palette_outlined : Icons.code_rounded,
                    color: cardColor,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              script.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          if (!script.enabled)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: (isDark
                                        ? AppTheme.textMuted
                                        : AppTheme.lightTextMuted)
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'OFF',
                                style: TextStyle(
                                  color: isDark
                                      ? AppTheme.textMuted
                                      : AppTheme.lightTextMuted,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.link_rounded,
                            size: 11,
                            color: textMuted,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              script.urlPattern,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: textMuted,
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Switch(
                  value: script.enabled,
                  activeThumbColor: Colors.white,
                  activeTrackColor: cardColor,
                  inactiveThumbColor:
                      isDark ? const Color(0xFF7F7F90) : const Color(0xFF94A3B8),
                  inactiveTrackColor:
                      isDark ? const Color(0x1AFFFFFF) : const Color(0x0D000000),
                  trackOutlineColor: WidgetStateProperty.resolveWith(
                      (states) => Colors.transparent),
                  onChanged: onToggle,
                ),
                IconButton(
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                  ),
                  tooltip: L10n.of(context, 'browser_delete'),
                  onPressed: onDelete,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ),
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
  _ScriptResult(
      this.name, this.urlPattern, this.code, this.isCss, this.permissions);
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
    this.initialPermissions = const {
      ScriptPermission.domRead,
      ScriptPermission.domWrite
    },
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

  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return AlertDialog(
      backgroundColor:
          (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(
        alpha: 0.97,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              widget.initialName.isEmpty ? Icons.add_rounded : Icons.edit_rounded,
              color: accent,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.initialName.isEmpty
                  ? L10n.of(context, 'browser_add_script')
                  : L10n.of(context, 'browser_edit_script'),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_errorMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.red.withValues(alpha: 0.3),
                    width: 0.7,
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        size: 16, color: Colors.red),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            TextField(
              controller: _nameC,
              decoration: InputDecoration(
                labelText: L10n.of(context, 'browser_script_name'),
                prefixIcon: Icon(Icons.label_outline, size: 18, color: accent),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _urlC,
              decoration: InputDecoration(
                labelText: L10n.of(context, 'browser_script_url_pattern'),
                prefixIcon:
                    Icon(Icons.link_rounded, size: 18, color: accent),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            Text(
              L10n.of(context, 'browser_script_type'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    label: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.code, size: 14, color: !_isCss ? accent : null),
                        const SizedBox(width: 6),
                        Text(L10n.of(context, 'browser_script_js')),
                      ],
                    ),
                    selected: !_isCss,
                    onSelected: (_) => setState(() => _isCss = false),
                    selectedColor: accent.withValues(alpha: 0.15),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ChoiceChip(
                    label: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.palette_outlined,
                            size: 14, color: _isCss ? accent : null),
                        const SizedBox(width: 6),
                        Text(L10n.of(context, 'browser_script_css')),
                      ],
                    ),
                    selected: _isCss,
                    onSelected: (_) => setState(() => _isCss = true),
                    selectedColor: accent.withValues(alpha: 0.15),
                  ),
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
                  color: isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: ScriptPermission.values.map((perm) {
                  final selected = _permissions.contains(perm);
                  return FilterChip(
                    label:
                        Text(perm.name, style: const TextStyle(fontSize: 11)),
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
                    selectedColor: accent.withValues(alpha: 0.15),
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: _codeC,
              maxLines: 8,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                labelText: L10n.of(context, 'browser_script_code'),
                alignLabelWithHint: true,
                prefixIcon: Icon(Icons.code_rounded, size: 18, color: accent),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
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
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: () {
            final name = _nameC.text.trim();
            final pattern = _urlC.text.trim();
            final code = _codeC.text.trim();
            if (name.isEmpty) {
              setState(() => _errorMessage = L10n.isRtl(context)
                  ? 'يرجى إدخال اسم السكريبت'
                  : 'Please enter script name');
              return;
            }
            if (pattern.isEmpty) {
              setState(() => _errorMessage = L10n.isRtl(context)
                  ? 'يرجى إدخال نمط الرابط'
                  : 'Please enter URL pattern');
              return;
            }
            if (code.isEmpty) {
              setState(() => _errorMessage =
                  L10n.isRtl(context) ? 'يرجى إدخال الكود' : 'Please enter script code');
              return;
            }
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