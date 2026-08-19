import 'dart:async';
import 'dart:math' as math;

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/database_service.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/search_engine_config.dart';

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

/// Ultra-modern, polished URL & search bar capsule with integrated progress,
/// dynamic protocol security badges, frosted glass autocomplete overlay,
/// and smooth focus transitions.
class SmartUrlBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isDark;
  final void Function(String url) onNavigate;
  final bool isLoading;
  final double progress;
  final VoidCallback? onReload;
  final VoidCallback? onStopLoading;
  final VoidCallback? onShieldPressed;
  final bool isHttps;

  const SmartUrlBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.isDark,
    required this.onNavigate,
    this.isLoading = false,
    this.progress = 0.0,
    this.onReload,
    this.onStopLoading,
    this.onShieldPressed,
    this.isHttps = false,
  });

  @override
  State<SmartUrlBar> createState() => _SmartUrlBarState();
}

class _SmartUrlBarState extends State<SmartUrlBar>
    with SingleTickerProviderStateMixin, HapticHelper {
  List<_Suggestion> _suggestions = [];
  Timer? _debounce;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  int _searchCount = 0;
  late AnimationController _progressAnimController;

  // FIX(P9): Cache the last suggestion query + results so a new query that is
  // simply an extension of the previous one can be filtered from cache instead
  // of re-querying the database.
  String _lastCachedQuery = '';
  List<_Suggestion> _cachedSuggestions = [];

  @override
  void initState() {
    super.initState();
    _progressAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    widget.controller.addListener(_onTextChanged);
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(SmartUrlBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
    if (widget.isLoading != oldWidget.isLoading ||
        widget.progress != oldWidget.progress) {
      if (widget.isLoading) {
        _progressAnimController.animateTo(
          widget.progress.clamp(0.05, 1.0),
          curve: Curves.easeOutCubic,
        );
      } else {
        _progressAnimController.animateTo(1.0).then((_) {
          if (mounted && !widget.isLoading) {
            _progressAnimController.reset();
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _progressAnimController.dispose();
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
        HapticHelper.triggerHaptic(settings);
      } catch (e, st) {
        LoggingService.logger('SmartUrlBar').warning('Operation failed', e, st);
      }
    }
    if (!widget.focusNode.hasFocus) {
      _removeOverlay();
    } else if (widget.controller.text.isNotEmpty) {
      _generateSuggestions(widget.controller.text);
    }
    if (mounted) setState(() {});
  }

  void _onTextChanged() {
    _debounce?.cancel();
    // FIX(P9): 250ms debounce so rapidly-typed queries don't hammer the DB.
    _debounce = Timer(const Duration(milliseconds: 250), () {
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
        icon: Icons.public_rounded,
      ));
    }

    // FIX(P9): If the new query extends the previously cached query, reuse the
    // cached bookmark/history results (filtered to the new prefix) instead of
    // hitting the database again.
    final isPrefixOfCached = query.length > _lastCachedQuery.length &&
        _lastCachedQuery.isNotEmpty &&
        query.startsWith(_lastCachedQuery);

    if (isPrefixOfCached) {
      for (final cached in _cachedSuggestions) {
        if (cached.type == SuggestionType.bookmark ||
            cached.type == SuggestionType.history) {
          final title = cached.title.toLowerCase();
          final url = cached.url.toLowerCase();
          if (title.contains(query) || url.contains(query)) {
            suggestions.add(cached);
          }
        }
      }
    } else {
      // 2. Fetch matching bookmarks and history from DatabaseService
      try {
        final db = context.read<DatabaseService>();
        final lowerQuery = query.toLowerCase();

        // Bookmarks match
        final matchingBookmarks =
            await db.searchBookmarks(lowerQuery, limit: 3);

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
              !suggestions
                  .any((s) => s.url.toLowerCase() == url.toLowerCase())) {
            suggestions.add(_Suggestion(
              type: SuggestionType.history,
              title: title.isNotEmpty ? title : url,
              url: url,
              icon: Icons.history_rounded,
            ));
          }
        }
      } catch (e, st) {
        LoggingService.logger('SmartUrlBar').warning('Operation failed', e, st);
      }
    }

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

    // FIX(P9): Update the suggestion cache only when this query hit the DB
    // (not a prefix-filtered reuse), keeping the cache aligned with the
    // freshest query.
    if (!isPrefixOfCached) {
      _lastCachedQuery = query;
      _cachedSuggestions = List<_Suggestion>.from(suggestions);
    }

    // Cap total suggestions at 5
    _suggestions = suggestions.take(5).toList();

    if (_suggestions.isNotEmpty && widget.focusNode.hasFocus) {
      _showOverlay();
    } else {
      _removeOverlay();
    }
  }

  String _formatSearchUrl(String query, String engine) {
    final prefix = SearchEngineConfig.prefixFor(engine);
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

    final renderBox = context.findRenderObject() as RenderBox?;
    final targetOffset = renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
    final top = targetOffset.dy + (renderBox?.size.height ?? 42) + 8;

    _overlayEntry = OverlayEntry(
      builder: (ctx) {
        // FIX(B10): Clamp the suggestion overlay above the on-screen keyboard
        // by accounting for the keyboard inset, so the list never renders
        // underneath the keyboard when the soft input is open.
        final viewInsets = MediaQuery.of(ctx).viewInsets.bottom;
        final visibleHeight = MediaQuery.of(ctx).size.height - viewInsets;
        final effectiveTop =
            viewInsets > 0 ? math.min(top, visibleHeight - 64) : top;
        return Stack(
          children: [
            // Barrier behind overlay
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

            // Elevated Frosted Glass Suggestion Container
            Positioned(
              top: effectiveTop,
              left: 12,
              right: 12,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: DmxBackdropFilter(
                      sigmaX: 16,
                      sigmaY: 16,
                      child: Material(
                        elevation: 20,
                        shadowColor: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(20),
                        color: isDark
                            ? (isAmoled
                                ? const Color(0xFF0F0F14)
                                    .withValues(alpha: 0.98)
                                : const Color(0xFF1A1A26)
                                    .withValues(alpha: 0.92))
                            : Colors.white.withValues(alpha: 0.94),
                        child: Container(
                          constraints: BoxConstraints(
                            maxHeight: MediaQuery.of(ctx).size.height * 0.45,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isDark
                                  ? (isAmoled
                                      ? AppTheme.amoledBorder
                                      : AppTheme.glassBorder)
                                  : AppTheme.lightGlassBorder,
                              width: 1.0,
                            ),
                          ),
                          child: ListView.separated(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 8),
                            shrinkWrap: true,
                            itemCount: _suggestions.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 4),
                            itemBuilder: (context, index) {
                              final s = _suggestions[index];
                              final badgeColor = switch (s.type) {
                                SuggestionType.search =>
                                  isDark ? AppTheme.neonViolet : Colors.purple,
                                SuggestionType.bookmark => isDark
                                    ? AppTheme.neonAmber
                                    : Colors.amber.shade800,
                                SuggestionType.history => isDark
                                    ? AppTheme.neonBlue
                                    : Colors.blue.shade700,
                                SuggestionType.url => isDark
                                    ? AppTheme.neonGreen
                                    : Colors.green.shade700,
                              };

                              return Container(
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? (isAmoled
                                          ? AppTheme.amoledCardBg
                                          : Colors.white
                                              .withValues(alpha: 0.04))
                                      : Colors.black.withValues(alpha: 0.03),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isDark
                                        ? Colors.white.withValues(alpha: 0.06)
                                        : Colors.black.withValues(alpha: 0.05),
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
                                              color: badgeColor.withValues(
                                                  alpha: 0.14),
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(
                                              s.icon,
                                              size: 16,
                                              color: badgeColor,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  s.title,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                    color: isDark
                                                        ? AppTheme.textPrimary
                                                        : AppTheme
                                                            .lightTextPrimary,
                                                  ),
                                                ),
                                                if (s.title != s.url &&
                                                    s.type !=
                                                        SuggestionType
                                                            .search) ...[
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    s.url,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: isDark
                                                          ? AppTheme.textMuted
                                                          : AppTheme
                                                              .lightTextMuted,
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
    _overlayEntry?.dispose();
    _overlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final muted = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final isFocused = widget.focusNode.hasFocus;

    bool isAmoled = false;
    try {
      final settings = context.read<SettingsProvider>();
      isAmoled = isDark && settings.isAmoledMode;
    } catch (_) {}

    final capsuleBg = isDark
        ? (isAmoled
            ? (isFocused ? AppTheme.amoledSurfaceRaised : AppTheme.amoledCardBg)
            : (isFocused
                ? AppTheme.surfaceRaised
                : AppTheme.surfaceRaised.withValues(alpha: 0.75)))
        : (isFocused
            ? Colors.white
            : AppTheme.lightSurfaceRaised.withValues(alpha: 0.85));

    final capsuleBorder = isFocused
        ? accent.withValues(alpha: isAmoled ? 0.8 : 0.6)
        : (isDark
            ? (isAmoled ? AppTheme.amoledBorder : AppTheme.glassBorder)
            : AppTheme.lightBorder);

    // FIX(U14): Dismiss the suggestion overlay whenever the surrounding
    // scrollable scrolls, so the dropdown never floats over scrolled content.
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (_overlayEntry != null && notification is UserScrollNotification) {
          _removeOverlay();
        }
        return false;
      },
      child: CompositedTransformTarget(
        link: _layerLink,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          height: 40,
          decoration: BoxDecoration(
            color: capsuleBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: capsuleBorder,
              width: isFocused ? 1.4 : 0.9,
            ),
            boxShadow: isFocused
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.16),
                      blurRadius: 8,
                      spreadRadius: 0.5,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withValues(
                          alpha: isDark ? (isAmoled ? 0.0 : 0.15) : 0.03),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Stack(
              children: [
                // Bottom Progress Bar
                if (widget.isLoading || _progressAnimController.value > 0.0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: AnimatedBuilder(
                      animation: _progressAnimController,
                      builder: (context, _) {
                        final val = _progressAnimController.value;
                        if (val <= 0.0) return const SizedBox.shrink();
                        return Container(
                          height: 2.5,
                          alignment: isRtl
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: val.clamp(0.0, 1.0),
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    accent,
                                    isDark
                                        ? AppTheme.neonGreen
                                        : AppTheme.lightNeonGreen,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                // Interactive Text Field & Icons
                Center(
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: widget.controller,
                    builder: (context, value, child) {
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
                        cursorColor: accent,
                        cursorWidth: 1.8,
                        cursorRadius: const Radius.circular(2),
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.textPrimary
                              : AppTheme.lightTextPrimary,
                          fontSize: 13.5,
                          fontWeight:
                              isFocused ? FontWeight.w500 : FontWeight.w400,
                          letterSpacing: -0.1,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: isRtl
                              ? 'ابحث أو أدخل عنوان URL...'
                              : 'Search or enter URL...',
                          hintStyle: TextStyle(
                            color: muted.withValues(alpha: 0.8),
                            fontSize: 12.5,
                            fontWeight: FontWeight.normal,
                          ),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 2, vertical: 8),
                          prefixIconConstraints:
                              const BoxConstraints(minWidth: 38, minHeight: 38),
                          prefixIcon: GestureDetector(
                            onTap: () {
                              if (widget.onShieldPressed != null) {
                                final settings =
                                    context.read<SettingsProvider>();
                                HapticHelper.triggerHaptic(settings);
                                widget.onShieldPressed!();
                              }
                            },
                            child: Container(
                              margin: const EdgeInsets.only(left: 6, right: 4),
                              padding: const EdgeInsets.all(6),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 200),
                                child: Icon(
                                  isFocused
                                      ? Icons.search_rounded
                                      : (widget.isHttps
                                          ? Icons.lock_rounded
                                          : Icons.shield_outlined),
                                  key: ValueKey(
                                    isFocused
                                        ? 'search'
                                        : (widget.isHttps ? 'https' : 'http'),
                                  ),
                                  size: 16,
                                  color: isFocused
                                      ? accent
                                      : (widget.isHttps
                                          ? (isDark
                                              ? AppTheme.neonGreen
                                              : AppTheme.lightNeonGreen)
                                          : muted),
                                ),
                              ),
                            ),
                          ),
                          suffixIconConstraints:
                              const BoxConstraints(minWidth: 38, minHeight: 38),
                          suffixIcon: Padding(
                            padding: const EdgeInsets.only(right: 4, left: 4),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              child: IconButton(
                                key: ValueKey(
                                  widget.isLoading
                                      ? 'close'
                                      : (isFocused && hasText)
                                          ? 'clear'
                                          : 'refresh',
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 32, minHeight: 32),
                                icon: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: (isFocused && hasText)
                                      ? BoxDecoration(
                                          color: muted.withValues(alpha: 0.15),
                                          shape: BoxShape.circle,
                                        )
                                      : null,
                                  child: Icon(
                                    widget.isLoading
                                        ? Icons.close_rounded
                                        : (isFocused && hasText)
                                            ? Icons.close_rounded
                                            : Icons.refresh_rounded,
                                    size: (isFocused && hasText) ? 14 : 17,
                                    color: isFocused
                                        ? (hasText ? textClr(isDark) : accent)
                                        : muted,
                                  ),
                                ),
                                tooltip: widget.isLoading
                                    ? (isRtl ? 'إلغاء التحميل' : 'Stop loading')
                                    : (isFocused && hasText)
                                        ? (isRtl ? 'مسح' : 'Clear')
                                        : (isRtl ? 'إعادة تحميل' : 'Refresh'),
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
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color textClr(bool isDark) =>
      isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
}
