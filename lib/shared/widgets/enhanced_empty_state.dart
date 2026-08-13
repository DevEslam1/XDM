import 'package:flutter/material.dart';

enum EmptyStateType {
  downloads,
  search,
  history,
  bookmarks,
  network,
  custom,
}

class EnhancedEmptyState extends StatefulWidget {
  const EnhancedEmptyState({
    super.key,
    this.type = EmptyStateType.custom,
    this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.icon,
    this.tips = const [],
  });

  final EmptyStateType type;
  final String? title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData? icon;
  final List<String> tips;

  factory EnhancedEmptyState.noDownloads({
    VoidCallback? onAddDownload,
  }) =>
      EnhancedEmptyState(
        type: EmptyStateType.downloads,
        title: 'No Downloads Yet',
        subtitle: 'Add your first download by pasting a link or browsing.',
        actionLabel: 'Add Download',
        onAction: onAddDownload,
        icon: Icons.download_for_offline_outlined,
        tips: const [
          'Paste any direct URL to start downloading',
          'Use the built-in browser to automatically intercept downloads',
        ],
      );

  factory EnhancedEmptyState.noSearchResults({
    VoidCallback? onClearSearch,
  }) =>
      EnhancedEmptyState(
        type: EmptyStateType.search,
        title: 'No Matching Results',
        subtitle: 'Try adjusting your search terms or filter criteria.',
        actionLabel: 'Clear Search',
        onAction: onClearSearch,
        icon: Icons.search_off_rounded,
        tips: const [
          'Check for typos or misspellings',
          'Try broader search terms',
        ],
      );

  factory EnhancedEmptyState.noHistory({
    VoidCallback? onStartBrowsing,
  }) =>
      EnhancedEmptyState(
        type: EmptyStateType.history,
        title: 'No History',
        subtitle: 'Web pages you visit will appear here.',
        actionLabel: 'Start Browsing',
        onAction: onStartBrowsing,
        icon: Icons.history_rounded,
      );

  factory EnhancedEmptyState.noBookmarks({
    VoidCallback? onAddBookmark,
  }) =>
      EnhancedEmptyState(
        type: EmptyStateType.bookmarks,
        title: 'No Bookmarks Saved',
        subtitle: 'Bookmark your favorite websites for quick access.',
        actionLabel: 'Add Bookmark',
        onAction: onAddBookmark,
        icon: Icons.bookmark_border_rounded,
      );

  factory EnhancedEmptyState.networkError({
    VoidCallback? onRetry,
  }) =>
      EnhancedEmptyState(
        type: EmptyStateType.network,
        title: 'No Internet Connection',
        subtitle: 'Please check your network settings and try again.',
        actionLabel: 'Retry Connection',
        onAction: onRetry,
        icon: Icons.wifi_off_rounded,
      );

  @override
  State<EnhancedEmptyState> createState() => _EnhancedEmptyStateState();
}

class _EnhancedEmptyStateState extends State<EnhancedEmptyState>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  IconData _getIcon() {
    if (widget.icon != null) return widget.icon!;
    switch (widget.type) {
      case EmptyStateType.downloads:
        return Icons.cloud_download_outlined;
      case EmptyStateType.search:
        return Icons.search_rounded;
      case EmptyStateType.history:
        return Icons.history_rounded;
      case EmptyStateType.bookmarks:
        return Icons.bookmark_outline_rounded;
      case EmptyStateType.network:
        return Icons.wifi_off_rounded;
      case EmptyStateType.custom:
        return Icons.inbox_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primaryColor = theme.primaryColor;

    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _getIcon(),
                    size: 48,
                    color: primaryColor,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  widget.title ?? 'Nothing Here',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (widget.subtitle != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    widget.subtitle!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                if (widget.actionLabel != null && widget.onAction != null) ...[
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: widget.onAction,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(widget.actionLabel!),
                  ),
                ],
                if (widget.tips.isNotEmpty) ...[
                  const SizedBox(height: 32),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.grey.withValues(alpha: 0.1)
                          : Colors.grey.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark
                            ? Colors.white10
                            : Colors.black.withValues(alpha: 0.05),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.lightbulb_outline_rounded,
                                size: 16, color: primaryColor),
                            const SizedBox(width: 6),
                            Text(
                              'Quick Tips',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: primaryColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ...widget.tips.map(
                          (tip) => Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('• ',
                                    style: TextStyle(fontSize: 12)),
                                Expanded(
                                  child: Text(
                                    tip,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
