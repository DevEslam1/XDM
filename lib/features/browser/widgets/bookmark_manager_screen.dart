import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/services/database_service.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/bookmark.dart';

class BookmarkManagerScreen extends StatefulWidget {
  const BookmarkManagerScreen({super.key});

  @override
  State<BookmarkManagerScreen> createState() => _BookmarkManagerScreenState();
}

class _BookmarkManagerScreenState extends State<BookmarkManagerScreen> {
  late List<Bookmark> _bookmarks;

  @override
  void initState() {
    super.initState();
    _bookmarks = [];
    _load();
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
      debugPrint('[BookmarkManager] Failed to load bookmarks: $e');
      if (mounted) setState(() => _bookmarks = []);
    }
  }

  Future<void> _addBookmarkDialog() async {
    final result = await showDialog<_AddBookmarkResult>(
      context: context,
      builder: (_) => const _AddBookmarkDialog(),
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
    try {
      final db = context.read<DatabaseService>();
      await db.deleteBookmark(bm.id);
      await _load();
    } catch (e) {
      debugPrint('[BookmarkManager] Failed to delete bookmark: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return Scaffold(
      backgroundColor: isDark ? AppTheme.background : AppTheme.lightBackground,
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
      body: _bookmarks.isEmpty
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
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _bookmarks.length,
              separatorBuilder: (context, index) => const SizedBox(height: 6),
              itemBuilder: (context, i) {
                final bm = _bookmarks[i];
                return Container(
                  decoration: BoxDecoration(
                    color: (isDark ? AppTheme.glassBg : AppTheme.lightGlassBg).withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
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
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(Icons.bookmark, color: accent, size: 18),
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
                              icon: Icon(Icons.copy,
                                  size: 16,
                                  color: isDark
                                      ? AppTheme.textSecondary
                                      : AppTheme.lightTextSecondary),
                              tooltip: L10n.of(context, 'browser_menu_copy_url'),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: bm.url));
                                runHaptic(settings);
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
              },
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

  const _AddBookmarkDialog({
    this.initialTitle = '',
    this.initialUrl = '',
    this.initialFolder,
  });

  @override
  State<_AddBookmarkDialog> createState() => _AddBookmarkDialogState();
}

class _AddBookmarkDialogState extends State<_AddBookmarkDialog> {
  late final TextEditingController _titleC;
  late final TextEditingController _urlC;
  late final TextEditingController _folderC;

  @override
  void initState() {
    super.initState();
    _titleC = TextEditingController(text: widget.initialTitle);
    _urlC = TextEditingController(text: widget.initialUrl);
    _folderC = TextEditingController(text: widget.initialFolder ?? '');
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
    return AlertDialog(
      backgroundColor:
          (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.95),
      title: Text(widget.initialUrl.isEmpty
          ? L10n.of(context, 'browser_add_bookmark')
          : L10n.of(context, 'browser_edit_bookmark')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _titleC,
            decoration: InputDecoration(labelText: L10n.of(context, 'browser_title_label')),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlC,
            decoration: InputDecoration(labelText: L10n.of(context, 'browser_url_label')),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _folderC,
            decoration: InputDecoration(labelText: L10n.of(context, 'browser_folder_optional')),
          ),
        ],
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
            Navigator.pop(
              context,
              _AddBookmarkResult(
                _titleC.text.trim().isEmpty ? url : _titleC.text.trim(),
                url,
                _folderC.text.trim().isEmpty ? null : _folderC.text.trim(),
              ),
            );
          },
          child: Text(L10n.of(context, 'browser_save_btn')),
        ),
      ],
    );
  }
}
