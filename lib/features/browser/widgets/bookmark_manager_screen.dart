import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:logging/logging.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/services/database_service.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/bookmark.dart';

class BookmarkManagerScreen extends StatefulWidget {
  static final _log = Logger('BookmarkManagerScreen');
  const BookmarkManagerScreen({super.key});

  @override
  State<BookmarkManagerScreen> createState() => _BookmarkManagerScreenState();
}

class _BookmarkManagerScreenState extends State<BookmarkManagerScreen> {
  late List<Bookmark> _bookmarks;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<String> _collapsedFolders = {};

  @override
  void initState() {
    super.initState();
    _bookmarks = [];
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final db = context.read<DatabaseService>();
      final bms = await db.loadBookmarks();
      if (!mounted) return;
      setState(() {
        _bookmarks = bms;
      });
    } catch (e) {
      BookmarkManagerScreen._log
          .warning('[BookmarkManager] Failed to load bookmarks: $e');
      if (mounted) setState(() => _bookmarks = []);
    }
  }

  Set<String> get _existingFolders {
    return _bookmarks
        .map((b) => b.folder?.trim())
        .where((f) => f != null && f.isNotEmpty)
        .cast<String>()
        .toSet();
  }

  Future<void> _addBookmarkDialog() async {
    final result = await showDialog<_AddBookmarkResult>(
      context: context,
      builder: (_) => _AddBookmarkDialog(existingFolders: _existingFolders),
    );
    if (result == null) return;
    if (!mounted) return;
    final settings = context.read<SettingsProvider>();
    runHaptic(settings);
    final db = context.read<DatabaseService>();
    final bm = Bookmark(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: result.title,
      url: result.url,
      folder: result.folder,
      createdAt: DateTime.now(),
    );
    await db.saveBookmark(bm);
    _load();
  }

  Future<void> _editBookmarkDialog(Bookmark bm) async {
    final result = await showDialog<_AddBookmarkResult>(
      context: context,
      builder: (_) => _AddBookmarkDialog(
        initialTitle: bm.title,
        initialUrl: bm.url,
        initialFolder: bm.folder,
        existingFolders: _existingFolders,
      ),
    );
    if (result == null) return;
    if (!mounted) return;
    final db = context.read<DatabaseService>();
    await db.saveBookmark(bm.copyWith(
      title: result.title,
      url: result.url,
      folder: result.folder,
    ));
    _load();
  }

  Future<void> _delete(Bookmark bm) async {
    final db = context.read<DatabaseService>();
    final settings = context.read<SettingsProvider>();
    runHaptic(settings);

    try {
      await db.deleteBookmark(bm.id);
      await _load();

      if (!mounted) return;
      final isDark = settings.isDarkMode;
      final isRtl = L10n.isRtl(context);

      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 4),
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          content: Text(
            isRtl ? 'تم حذف الإشارة المرجعية' : 'Bookmark deleted',
            style: TextStyle(
              color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          action: SnackBarAction(
            label: isRtl ? 'تراجع' : 'UNDO',
            textColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            onPressed: () async {
              await db.saveBookmark(bm);
              _load();
            },
          ),
        ),
      );
    } catch (e) {
      BookmarkManagerScreen._log
          .warning('[BookmarkManager] Failed to delete bookmark: $e');
    }
  }

  Map<String, List<Bookmark>> _groupBookmarks(List<Bookmark> bms) {
    final filtered = bms.where((bm) {
      if (_searchQuery.isEmpty) return true;
      return bm.title.toLowerCase().contains(_searchQuery) ||
          bm.url.toLowerCase().contains(_searchQuery) ||
          (bm.folder?.toLowerCase().contains(_searchQuery) ?? false);
    }).toList();

    final Map<String, List<Bookmark>> groups = {};
    const unsortedKey = 'Unsorted';

    for (final bm in filtered) {
      final folder = (bm.folder != null && bm.folder!.trim().isNotEmpty)
          ? bm.folder!.trim()
          : unsortedKey;
      groups.putIfAbsent(folder, () => []).add(bm);
    }

    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final isAmoled = settings.isAmoledMode;
    final isRtl = L10n.isRtl(context);

    final grouped = _groupBookmarks(_bookmarks);

    return Scaffold(
      backgroundColor: AppTheme.getBackground(isDark, isAmoled: isAmoled),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(L10n.of(context, 'browser_bookmarks')),
        actions: [
          IconButton(
            icon: Icon(Icons.add, color: accent),
            tooltip: L10n.of(context, 'browser_add_bookmark'),
            onPressed: _addBookmarkDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          // Search Field
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: isRtl ? 'بحث في الإشارات المرجعية...' : 'Search bookmarks...',
                prefixIcon: Icon(Icons.search, size: 20, color: accent),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => _searchController.clear(),
                      )
                    : null,
                filled: true,
                fillColor: isDark
                    ? (isAmoled ? AppTheme.amoledCardBg : AppTheme.surface)
                    : AppTheme.lightSurface,
                contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          Expanded(
            child: _bookmarks.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bookmarks_outlined,
                            size: 56,
                            color: isDark
                                ? AppTheme.textMuted
                                : AppTheme.lightTextMuted),
                        const SizedBox(height: 14),
                        Text(L10n.of(context, 'browser_no_bookmarks'),
                            style: TextStyle(
                              color: isDark
                                  ? AppTheme.textPrimary
                                  : AppTheme.lightTextPrimary,
                              fontWeight: FontWeight.bold,
                            )),
                        const SizedBox(height: 6),
                        Text(L10n.of(context, 'browser_no_bookmarks_desc'),
                            style: TextStyle(
                              color: isDark
                                  ? AppTheme.textSecondary
                                  : AppTheme.lightTextSecondary,
                              fontSize: 12,
                            )),
                      ],
                    ),
                  )
                : grouped.isEmpty
                    ? Center(
                        child: Text(
                          isRtl ? 'لا توجد نتائج متطابقة' : 'No matching bookmarks',
                          style: TextStyle(
                            color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.all(12),
                        children: grouped.entries.map((entry) {
                          final folderName = entry.key;
                          final bmsInFolder = entry.value;
                          final isCollapsed = _collapsedFolders.contains(folderName);

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Folder Header
                              InkWell(
                                onTap: () {
                                  setState(() {
                                    if (isCollapsed) {
                                      _collapsedFolders.remove(folderName);
                                    } else {
                                      _collapsedFolders.add(folderName);
                                    }
                                  });
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                                  child: Row(
                                    children: [
                                      Icon(
                                        isCollapsed ? Icons.folder_outlined : Icons.folder_open_rounded,
                                        size: 20,
                                        color: accent,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        folderName,
                                        style: TextStyle(
                                          color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '(${bmsInFolder.length})',
                                        style: TextStyle(
                                          color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const Spacer(),
                                      Icon(
                                        isCollapsed
                                            ? Icons.keyboard_arrow_down_rounded
                                            : Icons.keyboard_arrow_up_rounded,
                                        color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                                        size: 20,
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                              if (!isCollapsed)
                                ...bmsInFolder.map((bm) {
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: _buildBookmarkTile(context, bm, isDark, isAmoled, accent),
                                  );
                                }),

                              const SizedBox(height: 8),
                            ],
                          );
                        }).toList(),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildBookmarkTile(
    BuildContext context,
    Bookmark bm,
    bool isDark,
    bool isAmoled,
    Color accent,
  ) {
    final domainAccent = bm.accentColor;

    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? (isAmoled
                ? AppTheme.amoledCardBg
                : AppTheme.glassBg.withValues(alpha: 0.4))
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
          onTap: () {
            Navigator.pop(context, bm.url);
          },
          onLongPress: () => _editBookmarkDialog(bm),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Color-coded Circle Avatar with initial letter
                CircleAvatar(
                  radius: 18,
                  backgroundColor: domainAccent.withValues(alpha: 0.2),
                  child: Text(
                    bm.initial,
                    style: TextStyle(
                      color: domainAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bm.title.isEmpty ? bm.url : bm.title,
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
                        bm.url,
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
                IconButton(
                  icon: Icon(Icons.edit_outlined,
                      size: 16,
                      color: isDark
                          ? AppTheme.textSecondary
                          : AppTheme.lightTextSecondary),
                  tooltip: L10n.of(context, 'browser_edit_bookmark'),
                  onPressed: () => _editBookmarkDialog(bm),
                ),
                IconButton(
                  icon: Icon(Icons.copy,
                      size: 16,
                      color: isDark
                          ? AppTheme.textSecondary
                          : AppTheme.lightTextSecondary),
                  tooltip: L10n.of(context, 'browser_menu_copy_url'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: bm.url));
                    runHaptic(context.read<SettingsProvider>());
                  },
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: 16,
                      color: isDark
                          ? AppTheme.neonRed
                          : AppTheme.lightNeonRed),
                  tooltip: L10n.of(context, 'browser_delete'),
                  onPressed: () => _delete(bm),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddBookmarkResult {
  final String title;
  final String url;
  final String? folder;
  _AddBookmarkResult(this.title, this.url, this.folder);
}

class _AddBookmarkDialog extends StatefulWidget {
  final String initialTitle;
  final String initialUrl;
  final String? initialFolder;
  final Set<String> existingFolders;

  const _AddBookmarkDialog({
    this.initialTitle = '',
    this.initialUrl = '',
    this.initialFolder,
    this.existingFolders = const {},
  });

  @override
  State<_AddBookmarkDialog> createState() => _AddBookmarkDialogState();
}

class _AddBookmarkDialogState extends State<_AddBookmarkDialog> {
  late final TextEditingController _titleC;
  late final TextEditingController _urlC;
  late final TextEditingController _folderC;
  String? _selectedFolder;
  bool _isNewFolder = false;

  @override
  void initState() {
    super.initState();
    _titleC = TextEditingController(text: widget.initialTitle);
    _urlC = TextEditingController(text: widget.initialUrl);
    final currentFolder = widget.initialFolder?.trim();

    if (currentFolder != null && currentFolder.isNotEmpty) {
      if (widget.existingFolders.contains(currentFolder)) {
        _selectedFolder = currentFolder;
        _folderC = TextEditingController();
      } else {
        _selectedFolder = '__new__';
        _isNewFolder = true;
        _folderC = TextEditingController(text: currentFolder);
      }
    } else {
      _selectedFolder = null;
      _folderC = TextEditingController();
    }
  }

  @override
  void dispose() {
    _titleC.dispose();
    _urlC.dispose();
    _folderC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

    final folderOptions = [
      DropdownMenuItem<String?>(
        value: null,
        child: Text(isRtl ? 'غير مصنف (افتراضي)' : 'Unsorted (Default)'),
      ),
      ...widget.existingFolders.map((f) => DropdownMenuItem<String?>(
            value: f,
            child: Text(f),
          )),
      DropdownMenuItem<String?>(
        value: '__new__',
        child: Text(
          isRtl ? '+ مجلد جديد...' : '+ New folder...',
          style: TextStyle(
            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    ];

    return AlertDialog(
      backgroundColor: (isDark ? AppTheme.surface : AppTheme.lightSurface)
          .withValues(alpha: 0.95),
      title: Text(widget.initialUrl.isEmpty
          ? L10n.of(context, 'browser_add_bookmark')
          : L10n.of(context, 'browser_edit_bookmark')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleC,
              decoration: InputDecoration(
                  labelText: L10n.of(context, 'browser_title_label')),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlC,
              decoration: InputDecoration(
                  labelText: L10n.of(context, 'browser_url_label')),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _selectedFolder,
              decoration: InputDecoration(
                labelText: isRtl ? 'المجلد' : 'Folder',
              ),
              items: folderOptions,
              onChanged: (val) {
                setState(() {
                  _selectedFolder = val;
                  _isNewFolder = val == '__new__';
                });
              },
            ),
            if (_isNewFolder) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _folderC,
                decoration: InputDecoration(
                  labelText: isRtl ? 'اسم المجلد الجديد' : 'New Folder Name',
                ),
              ),
            ],
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
            final url = _urlC.text.trim();
            if (url.isEmpty) return;

            String? folderResult;
            if (_isNewFolder) {
              folderResult = _folderC.text.trim().isEmpty ? null : _folderC.text.trim();
            } else {
              folderResult = _selectedFolder;
            }

            Navigator.pop(
              context,
              _AddBookmarkResult(
                _titleC.text.trim().isEmpty ? url : _titleC.text.trim(),
                url,
                folderResult,
              ),
            );
          },
          child: Text(L10n.of(context, 'browser_save_btn')),
        ),
      ],
    );
  }
}
