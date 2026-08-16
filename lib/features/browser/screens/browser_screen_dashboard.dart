part of 'browser_screen.dart';

/// The home-dashboard grid, shortcut cards, bookmarks/history entry
/// points.
mixin _DashboardMixin on _BrowserScreenStateBase {
  @override
  Widget _buildHomeDashboard(
    BuildContext context,
    SettingsProvider settings, {
    ScrollController? scrollController,
  }) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accentColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          BrowserHomePage(
            onSearchTap: () {
              _focusNode.requestFocus();
            },
            onBookmarksTap: () async {
              final cleared = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => const BookmarkManagerScreen(),
                ),
              );
              if (cleared == true && mounted) setState(() {});
            },
            onHistoryTap: () {
              _openHistory();
            },
          ),
          const SizedBox(height: 24),
          _SnifferRadarCard(
            settings: settings,
            isEnabled: _isSnifferEnabled,
            onToggle: (val) {
              triggerHaptic(settings);
              _setSnifferEnabled(val);
            },
          ),
          const SizedBox(height: 16),
          Selector<DownloadProvider, ({int active, String speed})>(
            selector: (_, p) => (
              active: p.downloadingTasksCount,
              speed: p.currentDownloadSpeedFormatted,
            ),
            builder: (context, stats, _) {
              if (stats.active == 0) return const SizedBox.shrink();
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
                      .withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color:
                        (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
                            .withValues(alpha: 0.25),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  children: [
                    _LiveDot(
                      color:
                          isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${stats.active} ${isRtl ? "تنزيل نشط" : "Active downloads"}',
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.textPrimary
                            : AppTheme.lightTextPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.speed_rounded,
                      size: 14,
                      color:
                          isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      stats.speed,
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.neonGreen
                            : AppTheme.lightNeonGreen,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        fontFamily: 'Space Grotesk',
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                isRtl ? 'محرك البحث:' : 'Search engine:',
                style: TextStyle(
                  color: isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: settings.searchEngine,
                dropdownColor:
                    isDark ? AppTheme.surface : AppTheme.lightSurface,
                menuMaxHeight: 250,
                underline: const SizedBox(),
                style: TextStyle(
                  color: accentColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
                icon: Icon(Icons.arrow_drop_down, color: accentColor, size: 16),
                items: SearchEngineConfig.engines.map((e) {
                  return DropdownMenuItem<String>(
                    value: e.name,
                    child: Text(e.name),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) {
                    triggerHaptic(settings);
                    settings.setSearchEngine(val);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 24),

          // ── Section 1: Your Shortcuts ───────────────────────────
          Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isRtl ? 'اختصاراتك' : 'Your shortcuts',
                style: TextStyle(
                  color: isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _showAddShortcutDialog,
                icon: Icon(Icons.add, size: 16, color: accentColor),
                label: Text(
                  isRtl ? 'إضافة' : 'Add',
                  style: TextStyle(
                      fontSize: 12,
                      color: accentColor,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ShortcutsGridWidget(
            customShortcuts: _userCustomShortcuts,
            isDark: isDark,
            isRtl: isRtl,
            settings: settings,
            onOpenBookmarks: () async {
              final cleared = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => const BookmarkManagerScreen(),
                ),
              );
              if (cleared == true && mounted) setState(() {});
            },
            onOpenHistory: _openHistory,
            onOpenScripts: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ScriptManagerScreen(),
                ),
              );
            },
            onRemoveShortcut: _removeCustomShortcut,
            onNavigate: (url) => _navigateToUrl(url),
          ),

          const SizedBox(height: 24),

          // ── Section 2: Suggested Sites ──────────────────────────
          Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isRtl ? 'المواقع المقترحة' : 'Suggested sites',
                style: TextStyle(
                  color: isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 2.5,
            children: [
              _buildShortcutCard(
                context,
                title: 'Google',
                url: 'https://google.com',
                icon: Icons.search,
                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                settings: settings,
              ),
              _buildShortcutCard(
                context,
                title: 'YouTube',
                url: 'https://youtube.com',
                icon: Icons.play_circle_fill,
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                settings: settings,
              ),
              _buildShortcutCard(
                context,
                title: 'TikTok',
                url: 'https://www.tiktok.com',
                icon: Icons.music_note,
                color:
                    isDark ? const Color(0xFFFE2C55) : const Color(0xFFE01E43),
                settings: settings,
              ),
              _buildShortcutCard(
                context,
                title: 'GitHub',
                url: 'https://github.com',
                icon: Icons.code,
                color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                settings: settings,
              ),
              _buildShortcutCard(
                context,
                title: 'Wikipedia',
                url: 'https://wikipedia.org',
                icon: Icons.menu_book_rounded,
                color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                settings: settings,
              ),
              _buildShortcutCard(
                context,
                title: 'DuckDuckGo',
                url: 'https://duckduckgo.com',
                icon: Icons.privacy_tip_outlined,
                color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
                settings: settings,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildShortcutCard(
    BuildContext context, {
    required String title,
    required String url,
    required IconData icon,
    required Color color,
    required SettingsProvider settings,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    final isDark = settings.isDarkMode;
    final textPrimary =
        isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    return GlassCard.listItem(
      borderRadius: 16,
      padding: EdgeInsets.zero,
      isDarkMode: isDark,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            triggerHaptic(settings);
            if (onTap != null) {
              onTap();
            } else {
              final activeTab = _tabs[_currentTabIndex];
              setState(() {
                activeTab.isHome = false;
              });
              _navigateToUrl(url);
            }
          },
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: color.withValues(alpha: 0.2),
                      width: 0.7,
                    ),
                  ),
                  child: Icon(icon, color: color, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: textPrimary,
                              fontSize: 13,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        url.replaceAll('https://', ''),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: isDark
                                  ? AppTheme.textMuted
                                  : AppTheme.lightTextMuted,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void _openBookmarks() async {
    final settings = _settings;
    triggerHaptic(settings);
    final url = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const BookmarkManagerScreen()),
    );
    if (url != null && url.isNotEmpty && mounted) {
      _navigateToUrl(url);
    }
  }

  @override
  void _openHistory() async {
    final settings = _settings;
    triggerHaptic(settings);
    final url = await BrowserHistorySheet.show(context);
    if (url != null && url.isNotEmpty && mounted) {
      _navigateToUrl(url);
    }
  }
}
