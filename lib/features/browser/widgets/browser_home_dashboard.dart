import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../screens/script_manager_screen.dart';
import '../services/browser_controller.dart';
import '../services/top_sites_cache_service.dart';
import 'bookmark_manager_screen.dart';
import 'browser_history_sheet.dart';
import 'browser_home_page.dart';
import 'browser_misc_dialogs.dart';
import 'search_engine_selector_widget.dart';
import 'shortcuts_grid_widget.dart';

class BrowserHomeDashboard extends StatefulWidget {
  final BrowserController controller;
  final SettingsProvider settings;
  final ScrollController? scrollController;

  const BrowserHomeDashboard({
    super.key,
    required this.controller,
    required this.settings,
    this.scrollController,
  });

  @override
  State<BrowserHomeDashboard> createState() => _BrowserHomeDashboardState();
}

class _BrowserHomeDashboardState extends State<BrowserHomeDashboard>
    with HapticHelper {
  final List<Map<String, String>> _userCustomShortcuts = [];
  List<Map<String, String>> _topHistorySites = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadCustomShortcuts();
        _loadTopHistorySites();
      }
    });
  }

  Future<void> _loadCustomShortcuts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('browser_custom_shortcuts');
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List;
        if (mounted) {
          setState(() {
            _userCustomShortcuts.clear();
            _userCustomShortcuts.addAll(
              decoded.map((e) => Map<String, String>.from(e as Map)),
            );
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _saveCustomShortcuts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'browser_custom_shortcuts', jsonEncode(_userCustomShortcuts));
    } catch (_) {}
  }

  Future<void> _loadTopHistorySites() async {
    try {
      final result = await TopSitesCacheService.instance.getTopSites(
        loader: () async {
          final history = await widget.controller.historyManager.getRecentHistory(limit: 30);
          final hostCounts = <String, int>{};
          final hostTitles = <String, String>{};
          final hostUrls = <String, String>{};

          for (final item in history) {
            final url = item['url'] as String? ?? '';
            final title = item['title'] as String? ?? '';
            final uri = Uri.tryParse(url);
            final host = uri?.host.toLowerCase() ?? '';
            if (host.isNotEmpty && host != 'localhost') {
              hostCounts[host] = (hostCounts[host] ?? 0) + 1;
              hostTitles[host] ??= title.isNotEmpty ? title : host;
              hostUrls[host] ??= url;
            }
          }

          final sortedHosts = hostCounts.keys.toList()
            ..sort((a, b) => hostCounts[b]!.compareTo(hostCounts[a]!));

          return sortedHosts.take(3).map((h) {
            return {
              'title': hostTitles[h] ?? h,
              'url': hostUrls[h] ?? 'https://$h',
            };
          }).toList();
        },
      );

      if (mounted) {
        setState(() {
          _topHistorySites = result;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accentColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          BrowserHomePage(
            onSearchTap: () {
              widget.controller.focusNode.requestFocus();
            },
            onBookmarksTap: () async {
              await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => const BookmarkManagerScreen(),
                ),
              );
            },
            onHistoryTap: () async {
              final url = await BrowserHistorySheet.show(context);
              if (url != null && url.isNotEmpty) {
                widget.controller.navigateToUrl(url);
              }
            },
            onDownloadsTap: () {
              HapticHelper.triggerHaptic(settings);
              context.read<DownloadProvider>().setActiveTabIndex(0);
            },
          ),
          const SizedBox(height: 20),

          // Media Sniffer Status Card (U8)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.surface : AppTheme.lightSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                width: 0.8,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: (widget.controller.isSnifferEnabled ? accentColor : Colors.grey)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.radar_rounded,
                    size: 18,
                    color: widget.controller.isSnifferEnabled ? accentColor : Colors.grey,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isRtl ? 'كاشف الوسائط التلقائي' : 'Media Sniffer Engine',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                        ),
                      ),
                      Text(
                        widget.controller.isSnifferEnabled
                            ? (isRtl ? 'جاهز لاقتناص الوسائط' : 'Ready to capture video/audio streams')
                            : (isRtl ? 'الكاشف متوقف مؤقتاً' : 'Sniffer is paused'),
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: widget.controller.isSnifferEnabled,
                  activeThumbColor: accentColor,
                  onChanged: (val) {
                    HapticHelper.triggerHaptic(settings);
                    widget.controller.setSnifferEnabled(val);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Download stats badge
          Selector<DownloadProvider, ({int active, String speed})>(
            selector: (_, p) => (
              active: p.downloadingTasksCount,
              speed: p.currentDownloadSpeedFormatted,
            ),
            shouldRebuild: (prev, next) =>
                prev.active != next.active || prev.speed != next.speed,
            builder: (context, stats, _) {
              if (stats.active == 0) return const SizedBox.shrink();
              return Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
                      .withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
                        .withValues(alpha: 0.25),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${stats.active} ${isRtl ? "تنزيل نشط" : "Active downloads"}',
                      style: TextStyle(
                        color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.speed_rounded,
                      size: 14,
                      color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      stats.speed,
                      style: TextStyle(
                        color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          // Search engine selector (U3)
          Center(
            child: SearchEngineSelectorWidget(
              settings: settings,
              isDark: isDark,
              isRtl: isRtl,
            ),
          ),
          const SizedBox(height: 20),

          // Shortcuts
          ShortcutsGridWidget(
            customShortcuts: _userCustomShortcuts,
            isDark: isDark,
            isRtl: isRtl,
            settings: settings,
            onOpenBookmarks: () async {
              await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => const BookmarkManagerScreen(),
                ),
              );
            },
            onOpenHistory: () async {
              final url = await BrowserHistorySheet.show(context);
              if (url != null && url.isNotEmpty) {
                widget.controller.navigateToUrl(url);
              }
            },
            onOpenScripts: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ScriptManagerScreen(),
                ),
              );
            },
            onAddShortcut: () {
              BrowserMiscDialogs.showAddShortcutDialog(
                context,
                settings: settings,
                onAdd: (title, url) {
                  setState(() {
                    _userCustomShortcuts.add({'title': title, 'url': url});
                  });
                  _saveCustomShortcuts();
                },
              );
            },
            onRemoveShortcut: (shortcut) {
              setState(() {
                _userCustomShortcuts.remove(shortcut);
              });
              _saveCustomShortcuts();
            },
            onNavigate: (url) => widget.controller.navigateToUrl(url),
          ),

          const SizedBox(height: 24),

          // Suggested & Most Visited Sites (U28: Personalized)
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
                _topHistorySites.isNotEmpty
                    ? (isRtl ? 'الأكثر زيارة والمقترحة' : 'Top & Suggested Sites')
                    : (isRtl ? 'المواقع المقترحة' : 'Suggested Sites'),
                style: TextStyle(
                  color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                  fontWeight: FontWeight.w600,
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
              // Top history items if present
              ..._topHistorySites.map((item) {
                return _buildShortcutCard(
                  context,
                  title: item['title']!,
                  url: item['url']!,
                  icon: Icons.history_rounded,
                  color: accentColor,
                );
              }),
              _buildShortcutCard(
                context,
                title: 'Google',
                url: 'https://google.com',
                icon: Icons.search,
                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
              ),
              _buildShortcutCard(
                context,
                title: 'YouTube',
                url: 'https://youtube.com',
                icon: Icons.play_circle_fill,
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
              ),
              _buildShortcutCard(
                context,
                title: 'GitHub',
                url: 'https://github.com',
                icon: Icons.code,
                color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
              ),
              _buildShortcutCard(
                context,
                title: 'Wikipedia',
                url: 'https://wikipedia.org',
                icon: Icons.menu_book_rounded,
                color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
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
  }) {
    final settings = widget.settings;
    final isDark = settings.isDarkMode;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticHelper.triggerHaptic(settings);
          widget.controller.navigateToUrl(url);
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.surface : AppTheme.lightSurface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 20, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
