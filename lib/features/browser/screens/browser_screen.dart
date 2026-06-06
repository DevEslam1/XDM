import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;

import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../settings/provider/settings_provider.dart';
import '../../add_download/screens/add_screen.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/models/download_task.dart';
import '../../../core/utils/haptic_helper.dart';
import '../models/bookmark.dart';
import '../widgets/browser_download_sheet.dart';
import '../widgets/bookmark_manager_screen.dart';
import '../widgets/browser_history_sheet.dart';
import '../services/ad_blocker.dart';
import '../services/browser_detector.dart';
import '../../add_download/widgets/youtube_quality_sheet.dart';
import '../../add_download/widgets/youtube_playlist_sheet.dart';

class BrowserTab {
  final String id;
  late final WebViewController controller;
  String url;
  String title;
  bool isIncognito;
  bool isLoading;
  double progress;
  bool isHome;
  bool canGoBack;
  bool canGoForward;

  BrowserTab({
    required this.id,
    required this.controller,
    required this.url,
    required this.title,
    this.isIncognito = false,
    this.isLoading = false,
    this.progress = 0.0,
    this.isHome = true,
    this.canGoBack = false,
    this.canGoForward = false,
  });
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> with HapticHelper {
  final List<BrowserTab> _tabs = [];
  int _currentTabIndex = 0;

  final TextEditingController _urlController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  bool _isFocused = false;
  bool _showBars = true;
  double _lastScrollY = 0;

  // Custom JS and CSS Injections
  String _customJs = '';
  String _customCss = '';

  // Sniffer and detected media
  final Map<String, String> _detectedDownloadUrls = {}; // tab.id -> url
  final Map<String, List<Map<String, dynamic>>> _detectedMediaSources = {}; // tab.url -> sources
  final Map<String, int> _detectedPlaylistUrls = {}; // tab.id -> video count
  final Set<String> _recordedHistoryThisSession = {};
  final ScrollController _dashboardScrollController = ScrollController();
  static const String _snifferPrefKey = 'browserSnifferEnabled';
  bool _isSnifferEnabled = true;

  static const String _longPressChannel = 'XDM_LongPress';
  static const String _kLongPressScript = '''
(function() {
  if (window.__xdmLongPressBound) return;
  window.__xdmLongPressBound = true;
  let touchTimer = null;
  let startX = 0, startY = 0;

  function isMedia(el) {
    if (!el) return null;
    if (el.tagName === 'A' && el.href) {
      return { type: 'link', url: el.href, text: (el.innerText || el.href).slice(0, 200) };
    }
    if (el.tagName === 'IMG' && el.src) {
      return { type: 'image', url: el.src, text: (el.alt || el.src).slice(0, 200) };
    }
    if (el.tagName === 'VIDEO' && (el.src || el.currentSrc)) {
      return { type: 'video', url: el.src || el.currentSrc, text: (el.title || el.src).slice(0, 200) };
    }
    if (el.tagName === 'AUDIO' && (el.src || el.currentSrc)) {
      return { type: 'audio', url: el.src || el.currentSrc, text: (el.title || el.src).slice(0, 200) };
    }
    if (el.tagName === 'SOURCE' && el.src && el.parentElement) {
      const parent = el.parentElement;
      if (parent.tagName === 'VIDEO' || parent.tagName === 'AUDIO') {
        return { type: parent.tagName.toLowerCase(), url: el.src, text: '' };
      }
    }
    return null;
  }

  function notify(url, type, text) {
    if (window.XDM_LongPress) {
      window.XDM_LongPress.postMessage(JSON.stringify({ url: url, type: type, text: text }));
    }
  }

  document.addEventListener('contextmenu', function(e) {
    const target = isMedia(e.target);
    if (target) {
      e.preventDefault();
      notify(target.url, target.type, target.text);
    }
  }, true);

  document.addEventListener('touchstart', function(e) {
    if (e.touches.length !== 1) return;
    startX = e.touches[0].clientX;
    startY = e.touches[0].clientY;
    const target = isMedia(e.target);
    if (target) {
      touchTimer = setTimeout(function() {
        notify(target.url, target.type, target.text);
      }, 600);
    }
  }, { passive: true });

  document.addEventListener('touchend', function() {
    if (touchTimer) { clearTimeout(touchTimer); touchTimer = null; }
  }, true);

  document.addEventListener('touchmove', function(e) {
    if (!touchTimer) return;
    const dx = Math.abs(e.touches[0].clientX - startX);
    const dy = Math.abs(e.touches[0].clientY - startY);
    if (dx > 10 || dy > 10) {
      clearTimeout(touchTimer);
      touchTimer = null;
    }
  }, { passive: true });
})();
''';

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      setState(() {
        _isFocused = _focusNode.hasFocus;
      });
    });
    _loadSnifferPref();
    _loadCustomJsCss();

    _urlController.addListener(() {
      setState(() {});
    });

    _dashboardScrollController.addListener(_onDashboardScroll);

    // Create the first tab
    final initialTab = _createNewTab();
    _tabs.add(initialTab);
  }

  BrowserTab _createNewTab({String initialUrl = 'about:blank', bool isIncognito = false}) {
    final id = '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}';
    final controller = WebViewController();
    final tab = BrowserTab(
      id: id,
      controller: controller,
      url: initialUrl,
      title: initialUrl == 'about:blank' ? 'New Tab' : initialUrl,
      isIncognito: isIncognito,
      isHome: initialUrl == 'about:blank',
    );

    final settings = Provider.of<SettingsProvider>(context, listen: false);

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel(
        _longPressChannel,
        onMessageReceived: (msg) => _handleLongPressMessageForTab(tab, msg),
      )
      ..setUserAgent(
        tab.isIncognito
            ? (settings.desktopMode
                ? 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
                : 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1')
            : (settings.desktopMode
                ? 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
                : null),
      )
      ..enableZoom(settings.pinchToZoom)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            if (mounted) {
              final downloadProvider = Provider.of<DownloadProvider>(context, listen: false);
              setState(() {
                tab.isLoading = true;
                tab.progress = 0.0;
                tab.url = _cleanUrl(url);
                if (url != 'about:blank') {
                  tab.isHome = false;
                }
                _showBars = true;
                _lastScrollY = 0;
                
                // Update URL text field if this is the active tab
                if (_tabs[_currentTabIndex].id == tab.id) {
                  _urlController.text = tab.url;
                }
              });
              downloadProvider.setNavbarVisible(true);
            }
            _injectLongPressScriptToTab(tab);
            _injectCustomJsCss(tab);
            _updateNavState();
          },
          onPageFinished: (url) {
            if (mounted) {
              setState(() {
                tab.isLoading = false;
                _detectedDownloadUrls.remove(tab.id);
              });
              
              tab.controller.getTitle().then((t) {
                if (t != null && t.isNotEmpty && mounted) {
                  setState(() {
                    tab.title = t;
                  });
                }
              });
            }
            _injectLongPressScriptToTab(tab);
            _injectCustomJsCss(tab);
            _updateNavState();
            
            // Trigger background DOM media scanner
            Future.delayed(const Duration(milliseconds: 1000), () {
              _scanPageMedia(tab);
            });
          },
          onProgress: (progress) {
            if (mounted) {
              setState(() {
                tab.progress = progress / 100;
              });
            }
          },
          onUrlChange: (change) {
            if (change.url != null) {
              final cleanUrl = _cleanUrl(change.url!);
              if (mounted) {
                setState(() {
                  tab.url = cleanUrl;
                  if (cleanUrl != 'about:blank') {
                    tab.isHome = false;
                  }
                  if (_tabs[_currentTabIndex].id == tab.id) {
                    _urlController.text = tab.url;
                  }
                });
                
                // Clear cached download/playlist tags on dynamic navigation & trigger scan
                _detectedDownloadUrls.remove(tab.id);
                _detectedPlaylistUrls.remove(tab.id);
                _scanPageMedia(tab);
                
                // Fetch new page title after a short delay for SPA rendering
                Future.delayed(const Duration(milliseconds: 1000), () {
                  if (mounted) {
                    tab.controller.getTitle().then((t) {
                      if (t != null && t.isNotEmpty && mounted) {
                        setState(() {
                          tab.title = t;
                        });
                      }
                    });
                  }
                });
              }
              if (!tab.isIncognito && !settings.incognitoEnabled) {
                _recordHistory(change.url!);
              }
            }
          },
          onNavigationRequest: (NavigationRequest request) {
            if (settings.adBlockerEnabled &&
                AdBlocker.shouldBlock(request.url)) {
              return NavigationDecision.prevent;
            }
            if (BrowserDetector.isAutoDownloadable(request.url)) {
              setState(() {
                _detectedDownloadUrls[tab.id] = request.url;
              });
            }
            if (_isSnifferEnabled && _isDownloadable(request.url)) {
              _showInterceptionSheet(context, request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..setOnScrollPositionChange((ScrollPositionChange change) {
        if (mounted && _tabs[_currentTabIndex].id == tab.id) {
          _handleScroll(change.y.toDouble());
        }
      });

    if (initialUrl != 'about:blank') {
      controller.loadRequest(Uri.parse(initialUrl));
    }

    return tab;
  }

  void _recordHistory(String url) {
    if (url.isEmpty || url == 'about:blank') return;
    if (_recordedHistoryThisSession.contains(url)) return;
    _recordedHistoryThisSession.add(url);
    try {
      final db = Provider.of<DatabaseService>(context, listen: false);
      db.addBrowserHistory({
        'url': url,
        'title': url,
        'visitedAt': DateTime.now().toIso8601String(),
      });
    } catch (_) {}
  }

  Future<void> _injectLongPressScriptToTab(BrowserTab tab) async {
    if (!mounted) return;
    try {
      await tab.controller.runJavaScript(_kLongPressScript);
    } catch (_) {}
  }

  void _handleLongPressMessageForTab(BrowserTab tab, JavaScriptMessage message) {
    if (!mounted) return;
    try {
      final raw = message.message;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final url = data['url'] as String? ?? '';
      final type = data['type'] as String? ?? 'link';
      if (url.isEmpty) return;
      final settings = Provider.of<SettingsProvider>(context, listen: false);
      triggerHaptic(settings);
      _showLongPressSheet(context, url, type);
    } catch (_) {}
  }

  void _onDashboardScroll() {
    if (!_dashboardScrollController.hasClients) return;
    final y = _dashboardScrollController.offset;
    _handleScroll(y);
  }

  void _handleScroll(double y) {
    if (!mounted) return;
    final downloadProvider = Provider.of<DownloadProvider>(context, listen: false);
    if (y <= 0) {
      if (!_showBars) {
        setState(() {
          _showBars = true;
        });
        downloadProvider.setNavbarVisible(true);
      }
      _lastScrollY = y;
    } else if (y - _lastScrollY > 15) {
      if (_showBars) {
        setState(() {
          _showBars = false;
        });
        downloadProvider.setNavbarVisible(false);
      }
      _lastScrollY = y;
    } else if (_lastScrollY - y > 15) {
      if (!_showBars) {
        setState(() {
          _showBars = true;
        });
        downloadProvider.setNavbarVisible(true);
      }
      _lastScrollY = y;
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _focusNode.dispose();
    _dashboardScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadSnifferPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getBool(_snifferPrefKey) ?? true;
      if (!mounted) return;
      setState(() {
        _isSnifferEnabled = value;
      });
    } catch (_) {}
  }

  Future<void> _setSnifferEnabled(bool value) async {
    setState(() {
      _isSnifferEnabled = value;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_snifferPrefKey, value);
    } catch (_) {}
  }

  Future<void> _loadCustomJsCss() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _customJs = prefs.getString('browser_custom_js') ?? '';
        _customCss = prefs.getString('browser_custom_css') ?? '';
      });
    } catch (_) {}
  }

  bool _isDownloadable(String url) {
    final cleanUrl = url.split('?').first.toLowerCase();
    final lowercaseUrl = url.toLowerCase();

    if (lowercaseUrl.startsWith('blob:') || lowercaseUrl.startsWith('data:')) {
      return false;
    }

    final extensions = [
      '.mp4', '.mkv', '.avi', '.mov', '.mp3', '.wav', '.flac', '.pdf',
      '.docx', '.xlsx', '.zip', '.rar', '.7z', '.apk', '.dmg', '.exe',
      '.tar', '.gz', '.iso', '.torrent', '.pkg'
    ];

    return extensions.any((ext) => cleanUrl.endsWith(ext) || lowercaseUrl.contains('$ext?') || lowercaseUrl.contains('$ext&')) ||
        lowercaseUrl.contains('/download') ||
        lowercaseUrl.contains('download_file') ||
        lowercaseUrl.contains('attachment');
  }

  void _updateNavState() async {
    if (_tabs.isEmpty) return;
    final activeTab = _tabs[_currentTabIndex];
    final canBack = await activeTab.controller.canGoBack();
    final canForward = await activeTab.controller.canGoForward();
    if (mounted) {
      setState(() {
        activeTab.canGoBack = canBack;
        activeTab.canGoForward = canForward;
      });
    }
  }

  void _navigateToUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return;

    final uri = Uri.tryParse(url);
    if (uri != null && uri.hasScheme) {
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        url = 'https://google.com/search?q=${Uri.encodeComponent(input)}';
      }
    } else {
      if (url.contains('.') && !url.contains(' ')) {
        url = 'https://$url';
      } else {
        url = 'https://google.com/search?q=${Uri.encodeComponent(url)}';
      }
    }

    final activeTab = _tabs[_currentTabIndex];
    setState(() {
      activeTab.isHome = false;
    });
    activeTab.controller.loadRequest(Uri.parse(url));
  }

  String _cleanUrl(String url) {
    if (url == 'about:blank') return '';
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return url;
    var clean = uri.toString();
    if (uri.query.isNotEmpty) {
      clean = '${uri.scheme}://${uri.host}${uri.path.isEmpty ? '' : uri.path}?${uri.query}';
    } else {
      clean = '${uri.scheme}://${uri.host}${uri.path.isEmpty ? '' : uri.path}';
    }
    if (clean.endsWith('/') && clean.length > 8) {
      clean = clean.substring(0, clean.length - 1);
    }
    return clean;
  }

  PopupMenuItem<String> _menuItem(IconData icon, String label, String value, Color textClr) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 16, color: textClr),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(color: textClr, fontSize: 12)),
        ],
      ),
    );
  }

  Future<void> _handleMenuAction(String value) async {
    final settings = context.read<SettingsProvider>();
    final activeTab = _tabs[_currentTabIndex];

    switch (value) {
      case 'show_bookmarks':
        _openBookmarks();
        break;
      case 'show_history':
        _openHistory();
        break;
      case 'reload':
        if (!activeTab.isHome) {
          await activeTab.controller.reload();
        }
        break;
      case 'bookmark':
        final currentUrl = _urlController.text.trim();
        if (currentUrl.isEmpty) return;
        try {
          final db = context.read<DatabaseService>();
          await db.saveBookmark(Bookmark(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            title: activeTab.title.isNotEmpty ? activeTab.title : currentUrl,
            url: currentUrl,
            createdAt: DateTime.now(),
          ));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Bookmark saved'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        } catch (_) {}
        break;
      case 'copy':
        final url = _urlController.text.trim();
        if (url.isNotEmpty) {
          await Clipboard.setData(ClipboardData(text: url));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('URL copied'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        }
        break;
      case 'share':
        final url = _urlController.text.trim();
        if (url.isNotEmpty) {
          await Share.share(url, subject: activeTab.title);
        }
        break;
      case 'desktop':
        await settings.setDesktopMode(!settings.desktopMode);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(settings.desktopMode
                  ? 'Desktop mode enabled — reloading'
                  : 'Mobile mode — reloading'),
              duration: const Duration(seconds: 2),
            ),
          );
          
          for (final t in _tabs) {
            await t.controller.setUserAgent(
              settings.desktopMode
                  ? 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
                  : null,
            );
            if (!t.isHome) {
              await t.controller.reload();
            }
          }
        }
        break;
      case 'adblock':
        await settings.setAdBlockerEnabled(!settings.adBlockerEnabled);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(settings.adBlockerEnabled
                  ? 'Ad blocker enabled'
                  : 'Ad blocker disabled'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        break;
      case 'incognito':
        await settings.setIncognitoEnabled(!settings.incognitoEnabled);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(settings.incognitoEnabled
                  ? 'Incognito mode ON — no history recorded'
                  : 'Incognito mode OFF'),
              duration: const Duration(seconds: 2),
            ),
          );
          if (settings.incognitoEnabled) {
            _recordedHistoryThisSession.clear();
            try {
              await context.read<DatabaseService>().clearBrowserHistory();
            } catch (_) {}
            
            // Clear current tabs cookies, cache, local storage
            final cookieManager = WebViewCookieManager();
            await cookieManager.clearCookies();
            for (final t in _tabs) {
              await t.controller.clearCache();
              await t.controller.clearLocalStorage();
            }
          }
        }
        break;
      case 'injector':
        _showJsCssInjectorDialog();
        break;
      case 'offline':
        _savePageOffline(activeTab);
        break;
    }
  }

  void _showLongPressSheet(BuildContext context, String url, String type) {
    BrowserDownloadSheet.show(
      context,
      url,
      type: type,
      onQuality: () => _showQualityPicker(url),
    );
  }

  void _showInterceptionSheet(BuildContext context, String downloadUrl) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    triggerHaptic(settings);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Directionality(
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            child: DmxBackdropFilter(
              sigmaX: 15,
              sigmaY: 15,
              child: Container(
                decoration: BoxDecoration(
                  color: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.85),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                  border: Border(
                    top: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, width: 0.8),
                    left: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, width: 0.8),
                    right: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, width: 0.8),
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 20),
                            decoration: BoxDecoration(
                              color: (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted).withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(
                                Icons.download_for_offline_outlined,
                                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              isRtl ? 'تم التقاط إشارة تنزيل' : 'INTERCEPTED DOWNLOAD SIGNAL',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.0,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          isRtl
                              ? 'اكتشف مستعرض XDM إشارة تنزيل قابلة للاعتراض:'
                              : 'XDM Scanner intercepted a downloadable stream signal:',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: (isDark ? AppTheme.background : AppTheme.lightBackground).withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, width: 0.8),
                          ),
                          child: Text(
                            downloadUrl,
                            style: TextStyle(
                              color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder),
                                  foregroundColor: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                ),
                                onPressed: () => Navigator.pop(context),
                                child: Text(isRtl ? 'متابعة التصفح' : 'CONTINUE BROWSING'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: NeonGlowButton(
                                isFilled: true,
                                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                                onPressed: () {
                                  Navigator.pop(context);
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => AddScreen(prefilledUrl: downloadUrl),
                                    ),
                                  );
                                },
                                text: isRtl ? 'تحميل' : 'DOWNLOAD',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // DOM Page Media Scanner
  Future<void> _scanPageMedia(BrowserTab tab) async {
    if (!mounted || tab.isHome) return;

    // YouTube Playlist detection — do this first before single video
    if (YoutubeService.isPlaylistUrl(tab.url)) {
      try {
        final info = await YoutubeService.getPlaylistInfo(tab.url);
        if (info != null && mounted) {
          final count = info['videoCount'] as int? ?? 0;
          setState(() {
            _detectedPlaylistUrls[tab.id] = count;
            // Also set a download URL so the FAB shows
            _detectedDownloadUrls[tab.id] = tab.url;
          });
        }
      } catch (_) {}
      // If it also has a video ID (e.g. watch?v=xxx&list=yyy),
      // still try to fetch the single video streams too
      if (YoutubeService.isYoutubeVideoUrl(tab.url)) {
        try {
          final youtubeStreams = await YoutubeService.getStreams(tab.url);
          if (youtubeStreams.isNotEmpty && mounted) {
            setState(() {
              _detectedMediaSources[tab.url] = youtubeStreams;
            });
          }
        } catch (_) {}
      }
      return;
    }

    // Direct YouTube single video streams capture
    if (YoutubeService.isYoutubeVideoUrl(tab.url)) {
      try {
        final youtubeStreams = await YoutubeService.getStreams(tab.url);
        if (youtubeStreams.isNotEmpty && mounted) {
          setState(() {
            _detectedMediaSources[tab.url] = youtubeStreams;
            if (_detectedDownloadUrls[tab.id] == null) {
              _detectedDownloadUrls[tab.id] = youtubeStreams.first['src'];
            }
          });
          return; // Skip normal DOM scanning since we retrieved streams via YouTube API
        }
      } catch (_) {}
    }

    try {
      final result = await tab.controller.runJavaScriptReturningResult('''
        (function() {
          var sources = [];
          var videos = document.getElementsByTagName('video');
          for (var i = 0; i < videos.length; i++) {
            var v = videos[i];
            if (v.src && v.src.trim() !== '' && !v.src.startsWith('blob:')) {
              sources.push({ src: v.src, label: 'Video Stream (Default)' });
            }
            var childSources = v.getElementsByTagName('source');
            for (var j = 0; j < childSources.length; j++) {
              var s = childSources[j];
              if (s.src && s.src.trim() !== '' && !s.src.startsWith('blob:')) {
                var label = s.getAttribute('label') || s.getAttribute('res') || s.getAttribute('type') || ('Resolution ' + (j + 1));
                sources.push({ src: s.src, label: label });
              }
            }
          }
          var audios = document.getElementsByTagName('audio');
          for (var i = 0; i < audios.length; i++) {
            var a = audios[i];
            if (a.src && a.src.trim() !== '' && !a.src.startsWith('blob:')) {
              sources.push({ src: a.src, label: 'Audio Stream' });
            }
          }
          return JSON.stringify(sources);
        })();
      ''');

      if (result is String && result.isNotEmpty && result != 'null') {
        var cleanResult = result;
        if (cleanResult.startsWith('"') && cleanResult.endsWith('"')) {
          try {
            cleanResult = jsonDecode(cleanResult);
          } catch (_) {
            if (cleanResult.length > 2) {
              cleanResult = cleanResult.substring(1, cleanResult.length - 1);
            }
          }
        }
        final List<dynamic> parsed = jsonDecode(cleanResult);
        if (parsed.isNotEmpty) {
          setState(() {
            _detectedMediaSources[tab.url] = parsed.map((e) => Map<String, dynamic>.from(e as Map)).toList();
            if (_detectedDownloadUrls[tab.id] == null) {
              _detectedDownloadUrls[tab.id] = parsed.first['src'];
            }
          });
        }
      }
    } catch (_) {}
  }

  // Show dialog to choose quality
  void _showQualityPicker(String url) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final detectedSources = _detectedMediaSources[url] ?? [];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: DmxBackdropFilter(
            sigmaX: 15,
            sigmaY: 15,
            child: Container(
              decoration: BoxDecoration(
                color: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.95),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border(
                  top: BorderSide(
                    color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                    width: 0.8,
                  ),
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 20),
                          decoration: BoxDecoration(
                            color: (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted).withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Text(
                        'SELECT VIDEO QUALITY',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (detectedSources.isNotEmpty) ...[
                        ...detectedSources.map((src) {
                          final label = src['label'] as String? ?? 'Alternative Stream';
                          final srcUrl = src['src'] as String? ?? '';
                          return _buildQualityTile(context, label, srcUrl, isDark, settings);
                        }),
                      ] else ...[
                        _buildQualityTile(context, '1080p (FHD)', url, isDark, settings),
                        _buildQualityTile(context, '720p (HD)', url, isDark, settings),
                        _buildQualityTile(context, '480p (SD)', url, isDark, settings),
                        _buildQualityTile(context, '360p (Low)', url, isDark, settings),
                      ]
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildQualityTile(BuildContext context, String label, String streamUrl, bool isDark, SettingsProvider settings) {
    return ListTile(
      leading: Icon(Icons.video_settings, color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary),
      title: Text(
        label,
        style: TextStyle(
          color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      onTap: () {
        Navigator.pop(context);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => AddScreen(prefilledUrl: streamUrl),
          ),
        );
      },
    );
  }

  // Shows all detected streams from FAB
  void _showDetectedMediaSheet(BuildContext context, String pageUrl) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final detectedSources = _detectedMediaSources[pageUrl] ?? [];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: DmxBackdropFilter(
            sigmaX: 15,
            sigmaY: 15,
            child: Container(
              decoration: BoxDecoration(
                color: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.95),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border(
                  top: BorderSide(
                    color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                    width: 0.8,
                  ),
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 20),
                          decoration: BoxDecoration(
                            color: (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted).withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Text(
                        'DETECTED MEDIA ON PAGE',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.4,
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: detectedSources.length,
                          separatorBuilder: (context, index) => const SizedBox(height: 6),
                          itemBuilder: (context, i) {
                            final src = detectedSources[i];
                            final label = src['label'] as String? ?? 'Media Stream ${i + 1}';
                            final srcUrl = src['src'] as String? ?? '';
                            return ListTile(
                              leading: Icon(Icons.play_circle_fill, color: accent),
                              title: Text(
                                label,
                                style: TextStyle(
                                  color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(
                                srcUrl,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                                  fontSize: 10,
                                ),
                              ),
                              trailing: Icon(Icons.download, size: 18, color: accent),
                              onTap: () {
                                Navigator.pop(context);
                                final title = src['title'] as String?;
                                final ext = src['ext'] as String?;
                                final label = src['label'] as String? ?? 'Media Stream ${i + 1}';
                                String? filename;
                                if (title != null && title.isNotEmpty) {
                                  filename = ext != null ? "$title.$ext" : title;
                                }
                                BrowserDownloadSheet.show(
                                  context,
                                  srcUrl,
                                  suggestedName: filename,
                                  type: label.toLowerCase().contains('audio') ? 'audio' : 'video',
                                  onQuality: () => _showQualityPicker(srcUrl),
                                );
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
          ),
        );
      },
    );
  }

  // JS/CSS Injector Dialog
  void _showJsCssInjectorDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return _JsCssInjectorDialog(
          initialJs: _customJs,
          initialCss: _customCss,
          onSave: (js, css) async {
            setState(() {
              _customJs = js;
              _customCss = css;
            });
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('browser_custom_js', js);
            await prefs.setString('browser_custom_css', css);

            // Apply immediately to the active tab
            _injectCustomJsCss(_tabs[_currentTabIndex]);
          },
        );
      },
    );
  }

  Future<void> _injectCustomJsCss(BrowserTab tab) async {
    if (!mounted || tab.isHome) return;
    if (_customJs.isNotEmpty) {
      try {
        await tab.controller.runJavaScript(_customJs);
      } catch (_) {}
    }
    if (_customCss.isNotEmpty) {
      try {
        final escapedCss = _customCss.replaceAll("'", "\\'").replaceAll("\n", " ");
        final cssScript = """
          (function() {
            var style = document.getElementById('xdm-custom-css');
            if (!style) {
              style = document.createElement('style');
              style.id = 'xdm-custom-css';
              document.head.appendChild(style);
            }
            style.innerHTML = '$escapedCss';
          })();
        """;
        await tab.controller.runJavaScript(cssScript);
      } catch (_) {}
    }
  }

  // Save Page Offline
  Future<void> _savePageOffline(BrowserTab tab) async {
    if (tab.isHome) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    triggerHaptic(settings);

    try {
      final result = await tab.controller.runJavaScriptReturningResult("document.documentElement.outerHTML");
      String rawHtml = '';
      if (result is String) {
        rawHtml = result;
        if (rawHtml.startsWith('"') && rawHtml.endsWith('"')) {
          try {
            rawHtml = jsonDecode(rawHtml);
          } catch (_) {
            if (rawHtml.length > 2) {
              rawHtml = rawHtml.substring(1, rawHtml.length - 1);
            }
          }
        }
      }

      if (rawHtml.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to read page content')),
          );
        }
        return;
      }

      String title = tab.title.isNotEmpty ? tab.title : 'Offline_Page';
      title = title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();

      final path = settings.customDownloadPath?.isNotEmpty == true
          ? settings.customDownloadPath!
          : await PermissionService().defaultDownloadDirectory();

      final filePath = p.join(path, "$title.html");
      final file = File(filePath);
      await file.writeAsString(rawHtml);

      // Create a finished DownloadTask in local Hive database
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      final size = rawHtml.codeUnits.length;

      final task = DownloadTask(
        id: id,
        fileName: "$title.html",
        url: tab.url,
        fileSize: size,
        downloadedBytes: size,
        category: "Document",
        status: DownloadStatus.completed,
        savePath: path,
        localFilePath: filePath,
        tempFilePath: "",
        threadCount: 1,
        chunks: [1.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        completedAt: DateTime.now(),
      );

      if (!mounted) return;
      final db = context.read<DatabaseService>();
      await db.saveTask(task);
      
      // Reload provider tasks
      if (mounted) {
        await context.read<DownloadProvider>().load(pauseOrphanDownloads: false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Page saved successfully as $title.html')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save page: $e')),
        );
      }
    }
  }

  void _showTabSwitcher(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.85,
              maxChildSize: 0.95,
              minChildSize: 0.5,
              builder: (context, controller) {
                return ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                  child: DmxBackdropFilter(
                    sigmaX: 15,
                    sigmaY: 15,
                    child: Container(
                      decoration: BoxDecoration(
                        color: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.95),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                        border: Border(
                          top: BorderSide(
                            color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                            width: 0.8,
                          ),
                        ),
                      ),
                      child: SafeArea(
                        child: Column(
                          children: [
                            // Header
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
                              child: Row(
                                children: [
                                  Text(
                                    'ACTIVE TABS',
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      color: accent,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.0,
                                    ),
                                  ),
                                  const Spacer(),
                                  // New Incognito Tab button
                                  IconButton(
                                    icon: Icon(Icons.visibility_off, color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet),
                                    tooltip: 'New Incognito Tab',
                                    onPressed: () {
                                      triggerHaptic(settings);
                                      setState(() {
                                        final tab = _createNewTab(isIncognito: true);
                                        _tabs.add(tab);
                                        _currentTabIndex = _tabs.length - 1;
                                        _urlController.text = '';
                                        _showBars = true;
                                      });
                                      Navigator.pop(context);
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  // New Tab button
                                  IconButton(
                                    icon: Icon(Icons.add, color: accent),
                                    tooltip: 'New Tab',
                                    onPressed: () {
                                      triggerHaptic(settings);
                                      setState(() {
                                        final tab = _createNewTab();
                                        _tabs.add(tab);
                                        _currentTabIndex = _tabs.length - 1;
                                        _urlController.text = '';
                                        _showBars = true;
                                      });
                                      Navigator.pop(context);
                                    },
                                  ),
                                ],
                              ),
                            ),
                            
                            // Grid of tabs
                            Expanded(
                              child: GridView.builder(
                                controller: controller,
                                padding: const EdgeInsets.all(16),
                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                  childAspectRatio: 0.9,
                                ),
                                itemCount: _tabs.length,
                                itemBuilder: (context, index) {
                                  final tab = _tabs[index];
                                  final isActive = index == _currentTabIndex;
                                  
                                  return GestureDetector(
                                    onTap: () {
                                      triggerHaptic(settings);
                                      setState(() {
                                        _currentTabIndex = index;
                                        _urlController.text = tab.isHome ? '' : tab.url;
                                        _showBars = true;
                                      });
                                      Navigator.pop(context);
                                    },
                                    child: GlassCard(
                                      borderRadius: 16,
                                      padding: const EdgeInsets.all(12),
                                      isDarkMode: isDark,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          border: isActive
                                              ? Border.all(color: tab.isIncognito ? (isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet) : accent, width: 2)
                                              : null,
                                          borderRadius: BorderRadius.circular(16),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.all(8.0),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Icon(
                                                    tab.isIncognito ? Icons.visibility_off : Icons.language,
                                                    size: 14,
                                                    color: tab.isIncognito ? (isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet) : accent,
                                                  ),
                                                  const Spacer(),
                                                  IconButton(
                                                    icon: const Icon(Icons.close, size: 16),
                                                    padding: EdgeInsets.zero,
                                                    constraints: const BoxConstraints(),
                                                    onPressed: () {
                                                      triggerHaptic(settings);
                                                      setModalState(() {
                                                        setState(() {
                                                          _detectedDownloadUrls.remove(tab.id);
                                                          _tabs.removeAt(index);
                                                          
                                                          if (_currentTabIndex >= _tabs.length) {
                                                            _currentTabIndex = _tabs.length - 1;
                                                          }
                                                          if (_tabs.isEmpty) {
                                                            _tabs.add(_createNewTab());
                                                            _currentTabIndex = 0;
                                                          }
                                                          final activeTab = _tabs[_currentTabIndex];
                                                          _urlController.text = activeTab.isHome ? '' : activeTab.url;
                                                        });
                                                      });
                                                    },
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 12),
                                              Expanded(
                                                child: Text(
                                                  tab.title.isEmpty ? 'New Tab' : tab.title,
                                                  maxLines: 2,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                tab.isHome ? 'Dashboard' : tab.url,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                                                  fontSize: 9,
                                                ),
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
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildHomeDashboard(BuildContext context, SettingsProvider settings) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accentColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return SingleChildScrollView(
      controller: _dashboardScrollController,
      padding: const EdgeInsets.all(24.0),
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          Center(
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: accentColor.withValues(alpha: 0.3),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    Icons.language,
                    size: 48,
                    color: accentColor,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'XDM // WEB SANDBOX',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2.0,
                    fontSize: 18,
                    color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  isRtl
                      ? 'متصفح آمن لاعتراض وتنزيل الوسائط والملفات'
                      : 'Secure environment for stream interception & download capture',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Sniffer Toggle Card
          GlassCard(
            borderRadius: 20,
            padding: const EdgeInsets.all(16),
            isDarkMode: isDark,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isRtl ? 'حالة كاشف الملفات (Sniffer)' : 'STREAM SNIFFER STATUS',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: accentColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 9,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isSnifferEnabled
                            ? (isRtl ? 'الاعتراض التلقائي نشط' : 'AUTO-INTERCEPT ACTIVE')
                            : (isRtl ? 'الاعتراض التلقائي متوقف' : 'AUTO-INTERCEPT DEACTIVATED'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isRtl
                            ? 'يكتشف روابط التحميل المباشرة والوسائط تلقائياً'
                            : 'Sniffs media files and documents dynamically',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _isSnifferEnabled,
                  activeThumbColor: accentColor,
                  onChanged: (val) {
                    triggerHaptic(settings);
                    _setSnifferEnabled(val);
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 30),

          Text(
            isRtl ? 'إشارات سريعة (روابط)' : 'QUICK SIGNALS (BOOKMARKS)',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 2.2,
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
                title: 'Archive.org',
                url: 'https://archive.org',
                icon: Icons.history_edu,
                color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
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
                title: 'Sample Files',
                url: 'https://file-examples.com',
                icon: Icons.insert_drive_file_outlined,
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
  }) {
    final isDark = settings.isDarkMode;
    final textPrimary = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    return GlassCard(
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
            final activeTab = _tabs[_currentTabIndex];
            setState(() {
              activeTab.isHome = false;
            });
            _navigateToUrl(url);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    icon,
                    color: color,
                    size: 20,
                  ),
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
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        url.replaceAll('https://', ''),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                          fontSize: 9,
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
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final downloadProvider = context.watch<DownloadProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final statusBarHeight = MediaQuery.of(context).padding.top;

    if (_tabs.isEmpty) {
      return const SizedBox.shrink();
    }
    final activeTab = _tabs[_currentTabIndex];
    final showFab = !activeTab.isHome && 
        (_detectedDownloadUrls[activeTab.id] != null || 
         (_detectedMediaSources[activeTab.url]?.isNotEmpty ?? false) ||
         _detectedPlaylistUrls.containsKey(activeTab.id));

    // Reactively ensure zoom configuration matches settings changes
    activeTab.controller.enableZoom(settings.pinchToZoom);

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: showFab ? _buildDownloadFab(context, settings) : null,
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        body: Column(
          children: [
            // Custom collapsing App Bar
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              height: _showBars ? (kToolbarHeight + statusBarHeight) : 0,
              clipBehavior: Clip.hardEdge,
              decoration: const BoxDecoration(),
              child: DmxBackdropFilter(
                sigmaX: 12,
                sigmaY: 12,
                child: Container(
                  padding: EdgeInsets.only(top: statusBarHeight),
                  height: kToolbarHeight + statusBarHeight,
                  decoration: BoxDecoration(
                    color: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.5),
                    border: Border(
                      bottom: BorderSide(
                        color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                        width: 0.8,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Row(
                      children: [
                        // Back to Home / Close Button
                        IconButton(
                          icon: Icon(Icons.close, size: 20, color: textClr),
                          tooltip: isRtl ? 'العودة للرئيسية' : 'Back to Home',
                          onPressed: () {
                            triggerHaptic(settings);
                            setState(() {
                              activeTab.isHome = true;
                              activeTab.url = 'about:blank';
                              activeTab.title = 'New Tab';
                              _showBars = true;
                              _lastScrollY = 0;
                              _urlController.text = '';
                            });
                            downloadProvider.setActiveTabIndex(0);
                            downloadProvider.setNavbarVisible(true);
                            if (_dashboardScrollController.hasClients) {
                              _dashboardScrollController.jumpTo(0);
                            }
                            activeTab.controller.loadRequest(Uri.parse('about:blank'));
                          },
                        ),
                        const SizedBox(width: 4),
                        
                        // Address bar
                        Expanded(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            height: 36,
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF0F0F16) : const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: _isFocused
                                    ? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue).withValues(alpha: 0.5)
                                    : (isDark ? const Color(0x15FFFFFF) : const Color(0x0D000000)),
                                width: _isFocused ? 1.2 : 0.8,
                              ),
                              boxShadow: (_isFocused && isDark && settings.enableGlow)
                                  ? [
                                      BoxShadow(
                                        color: (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue).withValues(alpha: 0.25),
                                        blurRadius: 8,
                                        spreadRadius: 0.5,
                                      )
                                    ]
                                  : null,
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Row(
                              children: [
                                if (activeTab.isIncognito) ...[
                                  const SizedBox(width: 8),
                                  Icon(
                                    Icons.visibility_off,
                                    size: 14,
                                    color: isDark
                                        ? AppTheme.neonViolet
                                        : AppTheme.lightNeonViolet,
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                Expanded(
                                  child: TextField(
                                    controller: _urlController,
                                    focusNode: _focusNode,
                                    textAlignVertical: TextAlignVertical.center,
                                    style: TextStyle(
                                      color: textClr,
                                      fontSize: 13,
                                    ),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      prefixIcon: Icon(
                                        activeTab.isHome ? Icons.search : Icons.language,
                                        color: _isFocused
                                            ? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue)
                                            : (isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary),
                                        size: 16,
                                      ),
                                      prefixIconConstraints: const BoxConstraints(
                                        minWidth: 32,
                                        minHeight: 32,
                                      ),
                                      suffixIcon: _urlController.text.isNotEmpty
                                          ? IconButton(
                                              padding: EdgeInsets.zero,
                                              constraints: const BoxConstraints(),
                                              icon: Icon(
                                                Icons.clear,
                                                size: 16,
                                                color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                                              ),
                                              onPressed: () {
                                                triggerHaptic(settings);
                                                _urlController.clear();
                                                setState(() {});
                                              },
                                            )
                                          : null,
                                      suffixIconConstraints: const BoxConstraints(
                                        minWidth: 32,
                                        minHeight: 32,
                                      ),
                                      hintText: isRtl ? 'ابحث أو ادخل الرابط...' : 'SEARCH OR SCAN SIGNAL...',
                                      hintStyle: TextStyle(
                                        color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                                        fontSize: 11,
                                      ),
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                                    ),
                                    onSubmitted: _navigateToUrl,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),

                        // YouTube download button in appbar
                        if (!activeTab.isHome && (YoutubeService.isYoutubeVideoUrl(activeTab.url) || YoutubeService.isPlaylistUrl(activeTab.url))) ...[
                          IconButton(
                            icon: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.2),
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.red, width: 1.2),
                                boxShadow: settings.enableGlow
                                    ? [
                                        BoxShadow(
                                          color: Colors.red.withValues(alpha: 0.4),
                                          blurRadius: 6,
                                          spreadRadius: 0.5,
                                        )
                                      ]
                                    : null,
                              ),
                              child: Icon(
                                YoutubeService.isPlaylistUrl(activeTab.url)
                                    ? Icons.playlist_play_rounded
                                    : Icons.download_rounded,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                            tooltip: YoutubeService.isPlaylistUrl(activeTab.url)
                                ? (isRtl ? 'تحميل قائمة التشغيل' : 'Download Playlist')
                                : (isRtl ? 'تحميل الفيديو' : 'Download Video'),
                            onPressed: () async {
                              triggerHaptic(settings);
                              if (YoutubeService.isPlaylistUrl(activeTab.url)) {
                                final result = await YoutubePlaylistSheet.show(context, activeTab.url);
                                if (result != null && context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(isRtl
                                          ? 'تمت إضافة ${result.selectedVideos.length} فيديو إلى قائمة الانتظار'
                                          : '${result.selectedVideos.length} videos enqueued from "${result.playlistTitle}"'),
                                      duration: const Duration(seconds: 3),
                                    ),
                                  );
                                }
                              } else {
                                final detectedSources = _detectedMediaSources[activeTab.url] ?? [];
                                if (detectedSources.length > 1) {
                                  _showDetectedMediaSheet(context, activeTab.url);
                                } else {
                                  final stream = await YoutubeQualitySheet.show(context, activeTab.url);
                                  if (stream != null && context.mounted) {
                                    final title = stream['title'] as String? ?? 'YouTube Video';
                                    final ext = stream['ext'] as String? ?? 'mp4';
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => AddScreen(
                                          prefilledUrl: stream['src'] as String,
                                          prefilledName: '$title.$ext',
                                        ),
                                      ),
                                    );
                                  }
                                }
                              }
                            },
                          ),
                          const SizedBox(width: 4),
                        ],
                        
                        // Back navigation
                        IconButton(
                          icon: Icon(Icons.arrow_back_ios_new, size: 15, color: activeTab.canGoBack ? textClr : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted)),
                          onPressed: activeTab.canGoBack
                              ? () {
                                  triggerHaptic(settings);
                                  activeTab.controller.goBack();
                                }
                              : null,
                        ),
                        // Forward navigation
                        IconButton(
                          icon: Icon(Icons.arrow_forward_ios, size: 15, color: activeTab.canGoForward ? textClr : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted)),
                          onPressed: activeTab.canGoForward
                              ? () {
                                  triggerHaptic(settings);
                                  activeTab.controller.goForward();
                                }
                              : null,
                        ),

                        // Tab Switcher Button
                        GestureDetector(
                          onTap: () {
                            triggerHaptic(settings);
                            _showTabSwitcher(context);
                          },
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              border: Border.all(color: textClr, width: 1.8),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '${_tabs.length}',
                              style: TextStyle(
                                color: textClr,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),

                        // More menu options
                        PopupMenuButton<String>(
                          icon: Icon(Icons.more_vert, size: 18, color: textClr),
                          color: (isDark ? AppTheme.surface : AppTheme.lightSurface),
                          onSelected: (value) async {
                            triggerHaptic(settings);
                            await _handleMenuAction(value);
                          },
                          itemBuilder: (_) => [
                            _menuItem(
                              Icons.refresh,
                              'Reload',
                              'reload',
                              textClr,
                            ),
                            _menuItem(
                              Icons.bookmark_add_outlined,
                              'Bookmark this page',
                              'bookmark',
                              textClr,
                            ),
                            _menuItem(
                              Icons.bookmarks_outlined,
                              'Bookmarks Manager',
                              'show_bookmarks',
                              textClr,
                            ),
                            _menuItem(
                              Icons.history,
                              'Browser History',
                              'show_history',
                              textClr,
                            ),
                            _menuItem(
                              Icons.copy,
                              'Copy URL',
                              'copy',
                              textClr,
                            ),
                            _menuItem(
                              Icons.share,
                              'Share URL',
                              'share',
                              textClr,
                            ),
                            _menuItem(
                              Icons.save_alt,
                              'Save Page Offline',
                              'offline',
                              textClr,
                            ),
                            _menuItem(
                              Icons.code,
                              'Inject JS / CSS',
                              'injector',
                              textClr,
                            ),
                            const PopupMenuDivider(),
                            _menuItem(
                              settings.desktopMode ? Icons.smartphone : Icons.desktop_mac,
                              settings.desktopMode ? 'Mobile mode' : 'Desktop mode',
                              'desktop',
                              textClr,
                            ),
                            _menuItem(
                              settings.adBlockerEnabled ? Icons.shield : Icons.shield_outlined,
                              settings.adBlockerEnabled ? 'Ad blocker: ON' : 'Ad blocker: OFF',
                              'adblock',
                              textClr,
                            ),
                            _menuItem(
                              settings.incognitoEnabled ? Icons.visibility_off : Icons.visibility,
                              settings.incognitoEnabled ? 'Exit incognito' : 'New incognito tab',
                              'incognito',
                              textClr,
                            ),
                          ],
                          onOpened: () {
                            // Helper logic: since bookmarks & history sheets are pushed separately, 
                            // we handle their callbacks when they are selected.
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            
            // Loading Progress line
            if (activeTab.isLoading && !activeTab.isHome)
              LinearProgressIndicator(
                value: activeTab.progress,
                minHeight: 2.0,
                backgroundColor: Colors.transparent,
                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
              ),
              
            // Main browser view (preserving controllers state with IndexedStack)
            Expanded(
              child: Stack(
                children: [
                  GestureDetector(
                    onTap: () => _focusNode.unfocus(),
                    behavior: HitTestBehavior.translucent,
                    child: IndexedStack(
                      index: _currentTabIndex,
                      children: _tabs.map((tab) {
                        if (tab.isHome) {
                          return Container(
                            key: ValueKey('home_${tab.id}'),
                            child: _buildHomeDashboard(context, settings),
                          );
                        } else {
                          return Container(
                            key: ValueKey('web_${tab.id}'),
                            child: WebViewWidget(controller: tab.controller),
                          );
                        }
                      }).toList(),
                    ),
                  ),
                  
                  // Left edge gesture zone (Swipe edge -> Go Back)
                  if (!activeTab.isHome)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 28,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragEnd: (details) {
                          if (details.primaryVelocity != null && details.primaryVelocity! > 300) {
                            activeTab.controller.canGoBack().then((canGo) {
                              if (canGo) {
                                triggerHaptic(settings);
                                activeTab.controller.goBack();
                              }
                            });
                          }
                        },
                      ),
                    ),
                  
                  // Right edge gesture zone (Swipe edge -> Go Forward)
                  if (!activeTab.isHome)
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: 28,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragEnd: (details) {
                          if (details.primaryVelocity != null && details.primaryVelocity! < -300) {
                            activeTab.controller.canGoForward().then((canGo) {
                              if (canGo) {
                                triggerHaptic(settings);
                                activeTab.controller.goForward();
                              }
                            });
                          }
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Intercept bookmark and history opens from popups
  void _openBookmarks() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    triggerHaptic(settings);
    final url = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const BookmarkManagerScreen(),
      ),
    );
    if (url != null && url.isNotEmpty && mounted) {
      _navigateToUrl(url);
    }
  }

  void _openHistory() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    triggerHaptic(settings);
    final url = await BrowserHistorySheet.show(context);
    if (url != null && url.isNotEmpty && mounted) {
      _navigateToUrl(url);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Intercept bookmarks/history actions from menu popup selections 
    // outside of standard menu actions
  }

  // Handle manual navigation callbacks
  Widget _buildDownloadFab(BuildContext context, SettingsProvider settings) {
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final activeTab = _tabs[_currentTabIndex];
    final detectedSources = _detectedMediaSources[activeTab.url] ?? [];
    final isPlaylist = _detectedPlaylistUrls.containsKey(activeTab.id);
    final playlistCount = _detectedPlaylistUrls[activeTab.id] ?? 0;

    // YouTube Playlist FAB
    if (isPlaylist) {
      return FloatingActionButton.extended(
        heroTag: null,
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
        elevation: 4,
        onPressed: () async {
          triggerHaptic(settings);
          final result = await YoutubePlaylistSheet.show(context, activeTab.url);
          if (result != null && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${result.selectedVideos.length} videos enqueued from "${result.playlistTitle}"'),
                duration: const Duration(seconds: 3),
              ),
            );
          }
        },
        icon: const Icon(Icons.playlist_play_rounded),
        label: Text('PLAYLIST${playlistCount > 0 ? ' ($playlistCount)' : ''}'),
      );
    }

    // YouTube single video — show quality picker directly
    if (YoutubeService.isYoutubeVideoUrl(activeTab.url) && detectedSources.isNotEmpty) {
      return FloatingActionButton.extended(
        heroTag: null,
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
        elevation: 4,
        onPressed: () async {
          triggerHaptic(settings);
          if (detectedSources.length > 1) {
            _showDetectedMediaSheet(context, activeTab.url);
          } else {
            final stream = await YoutubeQualitySheet.show(context, activeTab.url);
            if (stream != null && context.mounted) {
              final title = stream['title'] as String? ?? 'YouTube Video';
              final ext = stream['ext'] as String? ?? 'mp4';
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AddScreen(
                    prefilledUrl: stream['src'] as String,
                    prefilledName: '$title.$ext',
                  ),
                ),
              );
            }
          }
        },
        icon: const Icon(Icons.play_circle_filled),
        label: Text(detectedSources.length > 1
            ? 'YOUTUBE (${detectedSources.length})'
            : 'YOUTUBE'),
      );
    }

    // Normal download FAB
    return FloatingActionButton.extended(
      heroTag: null,
      backgroundColor: accent,
      foregroundColor: Colors.black,
      elevation: 4,
      onPressed: () {
        triggerHaptic(settings);
        if (detectedSources.length > 1) {
          _showDetectedMediaSheet(context, activeTab.url);
        } else {
          final url = detectedSources.isNotEmpty 
              ? detectedSources.first['src'] 
              : _detectedDownloadUrls[activeTab.id];
          if (url == null) return;
          final title = detectedSources.isNotEmpty ? detectedSources.first['title'] as String? : null;
          final ext = detectedSources.isNotEmpty ? detectedSources.first['ext'] as String? : null;
          String? filename;
          if (title != null && title.isNotEmpty) {
            filename = ext != null ? "$title.$ext" : title;
          }
          BrowserDownloadSheet.show(
            context,
            url,
            suggestedName: filename,
            onQuality: () => _showQualityPicker(url),
          );
        }
      },
      icon: const Icon(Icons.download_rounded),
      label: Text(detectedSources.length > 1 
          ? 'DOWNLOADS (${detectedSources.length})' 
          : 'DOWNLOAD'),
    );
  }

}

// Stateful Dialog Editor for Injecting CSS & JavaScript
class _JsCssInjectorDialog extends StatefulWidget {
  final String initialJs;
  final String initialCss;
  final Function(String, String) onSave;

  const _JsCssInjectorDialog({
    required this.initialJs,
    required this.initialCss,
    required this.onSave,
  });

  @override
  State<_JsCssInjectorDialog> createState() => _JsCssInjectorDialogState();
}

class _JsCssInjectorDialogState extends State<_JsCssInjectorDialog> {
  late final TextEditingController _jsController;
  late final TextEditingController _cssController;
  int _activeTab = 0; // 0: JS, 1: CSS

  @override
  void initState() {
    super.initState();
    _jsController = TextEditingController(text: widget.initialJs);
    _cssController = TextEditingController(text: widget.initialCss);
  }

  @override
  void dispose() {
    _jsController.dispose();
    _cssController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return AlertDialog(
      backgroundColor: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.95),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        'JS / CSS INJECTOR',
        style: TextStyle(
          color: accent,
          fontSize: 14,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.0,
        ),
      ),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.85,
        height: 280,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _tabHeader(0, 'JavaScript'),
                ),
                Expanded(
                  child: _tabHeader(1, 'CSS Style'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: IndexedStack(
                index: _activeTab,
                children: [
                  _buildCodeEditor(_jsController, '// Write your Custom Javascript here\n// Automatically runs on page loads...', isDark),
                  _buildCodeEditor(_cssController, '/* Write your Custom CSS here */\nbody {\n  /* background-color: #000; */\n}', isDark),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.black,
          ),
          onPressed: () {
            widget.onSave(_jsController.text, _cssController.text);
            Navigator.pop(context);
          },
          child: const Text('APPLY'),
        ),
      ],
    );
  }

  Widget _tabHeader(int index, String label) {
    final isSelected = _activeTab == index;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final accent = settings.isDarkMode ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    return GestureDetector(
      onTap: () {
        runHaptic(settings);
        setState(() {
          _activeTab = index;
        });
      },
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected ? accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? accent : (settings.isDarkMode ? AppTheme.textSecondary : AppTheme.lightTextSecondary),
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildCodeEditor(TextEditingController controller, String hint, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.background : AppTheme.lightBackground).withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
          width: 0.8,
        ),
      ),
      child: TextField(
        controller: controller,
        maxLines: null,
        expands: true,
        keyboardType: TextInputType.multiline,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
            fontSize: 10,
          ),
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }
}
