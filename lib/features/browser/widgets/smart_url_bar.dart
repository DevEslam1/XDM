import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/database_service.dart';
import '../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';

import '../../../core/utils/haptic_helper.dart';

enum SuggestionType { url, search, bookmark, history }

class _Suggestion {
  final SuggestionType type;
  final String title;
  final String url;
  final IconData icon;

  const _Suggestion({
    required this.type,
    required this.title,
    required this.url,
    required this.icon,
  });
}

class SmartUrlBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isDark;
  final void Function(String url) onNavigate;
  final bool isLoading;
  final VoidCallback? onReload;
  final VoidCallback? onStopLoading;

  const SmartUrlBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.isDark,
    required this.onNavigate,
    this.isLoading = false,
    this.onReload,
    this.onStopLoading,
  });

  @override
  State<SmartUrlBar> createState() => _SmartUrlBarState();
}

class _SmartUrlBarState extends State<SmartUrlBar> with HapticHelper {
  List<_Suggestion> _suggestions = [];
  Timer? _debounce;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  int _searchCount = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _removeOverlay();
    widget.controller.removeListener(_onTextChanged);
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (widget.focusNode.hasFocus) {
      try {
        final settings = context.read<SettingsProvider>();
        lightPulse(settings);
      } catch (_) {}
    }
    if (!widget.focusNode.hasFocus) {
      _removeOverlay();
    } else if (widget.controller.text.isNotEmpty) {
      _generateSuggestions(widget.controller.text);
    }
  }

  void _onTextChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        _generateSuggestions(widget.controller.text);
      }
    });
  }

  Future<void> _generateSuggestions(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty || !widget.focusNode.hasFocus) {
      _suggestions = [];
      _removeOverlay();
      return;
    }

    final currentId = ++_searchCount;
    final suggestions = <_Suggestion>[];

    // 1. Direct URL match if query looks like a URL
    if (_looksLikeUrl(query)) {
      suggestions.add(_Suggestion(
        type: SuggestionType.url,
        title: query,
        url: _normalizeUrl(query),
        icon: Icons.link_rounded,
      ));
    }

    // 2. Fetch matching bookmarks and history from DatabaseService
    try {
      final db = context.read<DatabaseService>();
      final lowerQuery = query.toLowerCase();

      // Bookmarks match
      final bookmarks = await db.loadBookmarks();
      final matchingBookmarks = bookmarks.where((bm) {
        return bm.title.toLowerCase().contains(lowerQuery) ||
            bm.url.toLowerCase().contains(lowerQuery);
      }).take(3);

      for (final bm in matchingBookmarks) {
        suggestions.add(_Suggestion(
          type: SuggestionType.bookmark,
          title: bm.title.isNotEmpty ? bm.title : bm.url,
          url: bm.url,
          icon: Icons.bookmark_rounded,
        ));
      }

      // History match
      final historyRows = await db.loadBrowserHistory(
        searchQuery: query,
        max: 5,
      );

      for (final h in historyRows) {
        final url = h['url'] as String? ?? '';
        final title = h['title'] as String? ?? url;
        if (url.isNotEmpty &&
            !suggestions.any((s) => s.url.toLowerCase() == url.toLowerCase())) {
          suggestions.add(_Suggestion(
            type: SuggestionType.history,
            title: title.isNotEmpty ? title : url,
            url: url,
            icon: Icons.history_rounded,
          ));
        }
      }
    } catch (_) {}

    if (!mounted) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final engine = settings.searchEngine;
    final searchUrl = _formatSearchUrl(query, engine);

    suggestions.add(_Suggestion(
      type: SuggestionType.search,
      title: 'Search $engine for "$query"',
      url: searchUrl,
      icon: Icons.search_rounded,
    ));

    // Stale search check
    if (currentId != _searchCount || !mounted) return;

    // Cap total suggestions at 5
    _suggestions = suggestions.take(5).toList();

    if (_suggestions.isNotEmpty && widget.focusNode.hasFocus) {
      _showOverlay();
    } else {
      _removeOverlay();
    }
  }

  String _formatSearchUrl(String query, String engine) {
    String prefix = 'https://www.google.com/search?q=';
    if (engine == 'DuckDuckGo') {
      prefix = 'https://duckduckgo.com/?q=';
    } else if (engine == 'Bing') {
      prefix = 'https://www.bing.com/search?q=';
    } else if (engine == 'Yahoo') {
      prefix = 'https://search.yahoo.com/search?p=';
    } else if (engine == 'Brave') {
      prefix = 'https://search.brave.com/search?q=';
    } else if (engine == 'Ecosia') {
      prefix = 'https://www.ecosia.org/search?q=';
    }
    return '$prefix${Uri.encodeComponent(query)}';
  }

  bool _looksLikeUrl(String text) {
    return (text.contains('.') && !text.contains(' ')) ||
        text.startsWith('http') ||
        text.startsWith('magnet:') ||
        text.startsWith('file:');
  }

  String _normalizeUrl(String text) {
    if (text.startsWith('http://') ||
        text.startsWith('https://') ||
        text.startsWith('magnet:') ||
        text.startsWith('file:')) {
      return text;
    }
    return 'https://$text';
  }

  void _showOverlay() {
    _removeOverlay();
    final overlayState = Overlay.of(context);
    final isDark = widget.isDark;
    final settings = context.read<SettingsProvider>();
    final isAmoled = settings.isAmoledMode;

    _overlayEntry = OverlayEntry(
      builder: (ctx) {
        final box = context.findRenderObject() as RenderBox?;
        final dynamicTopBarOffset = box != null && box.attached
            ? box.localToGlobal(Offset.zero).dy + box.size.height + 6
            : MediaQuery.of(ctx).padding.top + 56;

        return Stack(
          children: [
            // Barrier behind overlay cards: tapping anywhere outside dismisses options and unfocuses
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  widget.focusNode.unfocus();
                  _removeOverlay();
                },
                child: const SizedBox.expand(),
              ),
            ),

            // Full-width cards container under top bar
            Positioned(
              top: dynamicTopBarOffset,
              left: 10,
              right: 10,
              child: Material(
                elevation: 12,
                shadowColor: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(20),
                color: isDark
                    ? (isAmoled ? AppTheme.surface : AppTheme.surface.withValues(alpha: 0.96))
                    : Colors.white.withValues(alpha: 0.96),
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 300),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isDark
                          ? (isAmoled ? AppTheme.amoledBorder : AppTheme.glassBorder)
                          : AppTheme.lightGlassBorder,
                      width: 0.8,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: ListView.separated(
                      padding: const EdgeInsets.all(8),
                      shrinkWrap: true,
                      itemCount: _suggestions.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final s = _suggestions[index];
                        final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

                        return Container(
                          decoration: BoxDecoration(
                            color: isDark
                                ? (isAmoled
                                    ? AppTheme.amoledCardBg
                                    : Colors.white.withValues(alpha: 0.05))
                                : Colors.black.withValues(alpha: 0.03),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isDark ? Colors.white10 : Colors.black12,
                              width: 0.5,
                            ),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                widget.focusNode.unfocus();
                                _removeOverlay();
                                widget.onNavigate(s.url);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: accent.withValues(alpha: 0.12),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        s.icon,
                                        size: 16,
                                        color: accent,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            s.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                              color: isDark
                                                  ? AppTheme.textPrimary
                                                  : AppTheme.lightTextPrimary,
                                            ),
                                          ),
                                          if (s.title != s.url &&
                                              s.type != SuggestionType.search) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              s.url,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: isDark
                                                    ? AppTheme.textMuted
                                                    : AppTheme.lightTextMuted,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Icon(
                                      Icons.north_west_rounded,
                                      size: 14,
                                      color: isDark
                                          ? AppTheme.textMuted
                                          : AppTheme.lightTextMuted,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    overlayState.insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final muted = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return CompositedTransformTarget(
      link: _layerLink,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: widget.controller,
        builder: (context, value, child) {
          final isFocused = widget.focusNode.hasFocus;
          final hasText = value.text.isNotEmpty;

          return TextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            textAlignVertical: TextAlignVertical.center,
            onTap: () {
              if (widget.controller.text.isNotEmpty) {
                _generateSuggestions(widget.controller.text);
              }
            },
            style: TextStyle(
              color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
              fontSize: 13,
            ),
            decoration: InputDecoration(
              isDense: true,
              hintText:
                  isRtl ? 'ابحث أو ادخل الرابط...' : 'Search or enter URL...',
              hintStyle: TextStyle(color: muted, fontSize: 11),
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              suffixIconConstraints:
                  const BoxConstraints(minWidth: 32, minHeight: 32),
              suffixIcon: IconButton(
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    widget.isLoading
                        ? Icons.close
                        : (isFocused && hasText)
                            ? Icons.clear
                            : Icons.refresh,
                    key: ValueKey(
                      widget.isLoading
                          ? 'close'
                          : (isFocused && hasText)
                              ? 'clear'
                              : 'refresh',
                    ),
                    size: 16,
                    color: isFocused
                        ? accent
                        : (isDark
                            ? AppTheme.textSecondary
                            : AppTheme.lightTextSecondary),
                  ),
                ),
                tooltip: widget.isLoading
                    ? (isRtl ? 'إلغاء التحميل' : 'Stop loading')
                    : (isFocused && hasText)
                        ? (isRtl ? 'مسح' : 'Clear')
                        : (isRtl ? 'إعادة تحميل الصفحة' : 'Refresh page'),
                onPressed: () {
                  if (widget.isLoading) {
                    widget.onStopLoading?.call();
                  } else if (isFocused && hasText) {
                    widget.controller.clear();
                  } else {
                    widget.onReload?.call();
                  }
                },
              ),
            ),
            onSubmitted: (val) {
              _removeOverlay();
              widget.focusNode.unfocus();
              widget.onNavigate(val);
            },
          );
        },
      ),
    );
  }
}
