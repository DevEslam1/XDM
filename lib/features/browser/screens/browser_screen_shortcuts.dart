part of 'browser_screen.dart';

/// Custom home-page shortcut CRUD (add/save/load/remove).
mixin _ShortcutsMixin on _BrowserScreenStateBase {
  @override
  Future<void> _showAddShortcutDialog() async {
    final titleC = TextEditingController();
    final urlC = TextEditingController();
    final isDark = context.read<SettingsProvider>().isDarkMode;
    final isRtl = L10n.isRtl(context);

    final res = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            isRtl ? 'إضافة اختصار جديد' : 'Add Custom Shortcut',
            style: TextStyle(
                color:
                    isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleC,
                decoration: InputDecoration(
                  labelText: isRtl ? 'العنوان' : 'Title',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlC,
                decoration: InputDecoration(
                  labelText: isRtl ? 'الرابط (URL)' : 'URL',
                ),
                keyboardType: TextInputType.url,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(isRtl ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(isRtl ? 'إضافة' : 'Add'),
            ),
          ],
        );
      },
    );

    if (res == true) {
      final title = titleC.text.trim();
      var url = urlC.text.trim();
      if (url.isNotEmpty) {
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
          url = 'https://$url';
        }
        setState(() {
          _userCustomShortcuts.add({
            'title': title.isNotEmpty ? title : url,
            'url': url,
          });
        });
        _saveCustomShortcuts(); // Bug #8 fix: persist to SharedPreferences
      }
    }
  }

  Future<void> _saveCustomShortcuts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'browser_custom_shortcuts', jsonEncode(_userCustomShortcuts));
    } catch (e) {
      _log.warning('Failed to save custom shortcuts: $e');
    }
  }

  @override
  Future<void> _loadCustomShortcuts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('browser_custom_shortcuts');
      if (raw != null) {
        final list = jsonDecode(raw) as List<dynamic>;
        if (mounted) {
          setState(() {
            _userCustomShortcuts.clear();
            for (final item in list) {
              Map<String, String> entry;
              if (item is Map<String, dynamic>) {
                entry = item.map((k, v) => MapEntry(k, v.toString()));
              } else if (item is Map) {
                entry =
                    item.map((k, v) => MapEntry(k.toString(), v.toString()));
              } else {
                continue;
              }
              final url = entry['url']?.trim() ?? '';
              if (url.isEmpty) continue;
              final title =
                  (entry['title']?.isNotEmpty ?? false) ? entry['title']! : url;
              _userCustomShortcuts.add({
                'title': title,
                'url': url,
              });
            }
          });
        }
      }
    } catch (e) {
      _log.warning('Failed to load custom shortcuts: $e');
    }
  }

  @override
  Future<void> _removeCustomShortcut(Map<String, String> shortcut) async {
    final isDark = context.read<SettingsProvider>().isDarkMode;
    final isRtl = L10n.isRtl(context);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            isRtl ? 'حذف الاختصار' : 'Remove Shortcut',
            style: TextStyle(
                color:
                    isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary),
          ),
          content: Text(
            isRtl
                ? 'هل تريد حذف هذا الاختصار؟'
                : 'Remove "${shortcut['title']}" from your shortcuts?',
            style: TextStyle(
                color: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(isRtl ? 'إلغاء' : 'Cancel'),
            ),
            ElevatedButton(
              style:
                  ElevatedButton.styleFrom(backgroundColor: AppTheme.neonRed),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(isRtl ? 'حذف' : 'Remove',
                  style: const TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      setState(() {
        _userCustomShortcuts.remove(shortcut);
      });
      _saveCustomShortcuts(); // Bug #8 fix: persist removal to SharedPreferences
    }
  }

  @override
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isControlPressed || hw.isMetaPressed;

    if (!ctrl) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.keyT:
        _openInNewTab('about:blank', switchToTab: true);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyW:
        final active = _tabManager.activeTab;
        if (active != null) {
          _tabManager.closeTab(active.id);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyR:
        final active = _tabManager.activeTab;
        if (active != null) {
          _safeReloadTab(active);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyL:
        _focusNode.requestFocus();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyD:
        _openBookmarks();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyH:
        _openHistory();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        if (hw.isAltPressed) {
          _tabManager.activeTab?.controller?.goBack();
          return KeyEventResult.handled;
        }
        break;
      case LogicalKeyboardKey.arrowRight:
        if (hw.isAltPressed) {
          _tabManager.activeTab?.controller?.goForward();
          return KeyEventResult.handled;
        }
        break;
    }

    return KeyEventResult.ignored;
  }
}
