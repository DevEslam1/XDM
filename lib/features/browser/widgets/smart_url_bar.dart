import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../settings/provider/settings_provider.dart';

enum SuggestionType { url, search }

class _Suggestion {
  final SuggestionType type;
  final String text;
  final IconData icon;

  const _Suggestion({
    required this.type,
    required this.text,
    required this.icon,
  });
}

class SmartUrlBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isDark;
  final void Function(String url) onNavigate;

  const SmartUrlBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.isDark,
    required this.onNavigate,
  });

  @override
  State<SmartUrlBar> createState() => _SmartUrlBarState();
}

class _SmartUrlBarState extends State<SmartUrlBar> {
  List<_Suggestion> _suggestions = [];
  bool _showSuggestions = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      _generateSuggestions(widget.controller.text);
    });
  }

  void _generateSuggestions(String query) {
    if (query.isEmpty) {
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
      });
      return;
    }

    final suggestions = <_Suggestion>[];

    if (_looksLikeUrl(query)) {
      suggestions.add(_Suggestion(
        type: SuggestionType.url,
        text: _normalizeUrl(query),
        icon: Icons.link_rounded,
      ));
    }

    suggestions.add(_Suggestion(
      type: SuggestionType.search,
      text: 'Search "$query"',
      icon: Icons.search_rounded,
    ));

    setState(() {
      _suggestions = suggestions;
      _showSuggestions = _suggestions.isNotEmpty && widget.focusNode.hasFocus;
    });
  }

  bool _looksLikeUrl(String text) {
    return (text.contains('.') && !text.contains(' ')) ||
        text.startsWith('http') ||
        text.startsWith('magnet:');
  }

  String _normalizeUrl(String text) {
    if (text.startsWith('http://') ||
        text.startsWith('https://') ||
        text.startsWith('magnet:')) {
      return text;
    }
    return 'https://$text';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final isAmoled = context.watch<SettingsProvider>().isAmoledMode;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          style: TextStyle(
            color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
            fontSize: 14,
          ),
          decoration: InputDecoration(
            hintText: 'Search or enter address',
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            filled: true,
            fillColor: isDark
                ? (isAmoled ? AppTheme.amoledBackground : const Color(0xFF0F0F16))
                : const Color(0xFFF1F5F9),
          ),
          onSubmitted: (val) {
            setState(() => _showSuggestions = false);
            final target = _looksLikeUrl(val)
                ? _normalizeUrl(val)
                : 'https://www.google.com/search?q=${Uri.encodeComponent(val)}';
            widget.onNavigate(target);
          },
        ),
        if (_showSuggestions)
          Container(
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: isDark
                  ? (isAmoled ? AppTheme.amoledSurface : AppTheme.surface)
                  : Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 8,
                ),
              ],
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _suggestions.length,
              itemBuilder: (context, index) {
                final s = _suggestions[index];
                return ListTile(
                  dense: true,
                  leading: Icon(s.icon, size: 16),
                  title: Text(s.text),
                  onTap: () {
                    setState(() => _showSuggestions = false);
                    final target = s.type == SuggestionType.url
                        ? s.text
                        : 'https://www.google.com/search?q=${Uri.encodeComponent(widget.controller.text)}';
                    widget.onNavigate(target);
                  },
                );
              },
            ),
          ),
      ],
    );
  }
}
