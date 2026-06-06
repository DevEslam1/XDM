import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../settings/provider/settings_provider.dart';
import '../../add_download/screens/add_screen.dart';
import '../../../core/utils/haptic_helper.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> with HapticHelper {
  late final WebViewController _webViewController;
  final TextEditingController _urlController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  
  bool _isLoading = false;
  double _loadingProgress = 0.0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  
  // Custom states
  bool _isHome = true;
  bool _isSnifferEnabled = true;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      setState(() {
        _isFocused = _focusNode.hasFocus;
      });
    });
    
    _urlController.addListener(() {
      setState(() {}); // Rebuild to update suffix clear button visibility
    });

    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            setState(() {
              _isLoading = true;
              _loadingProgress = 0.0;
              _urlController.text = url == 'about:blank' ? '' : url;
              if (url != 'about:blank') {
                _isHome = false;
              }
            });
            _updateNavState();
          },
          onPageFinished: (url) {
            setState(() {
              _isLoading = false;
            });
            _updateNavState();
          },
          onProgress: (progress) {
            setState(() {
              _loadingProgress = progress / 100;
            });
          },
          onNavigationRequest: (NavigationRequest request) {
            if (_isSnifferEnabled && _isDownloadable(request.url)) {
              _showInterceptionSheet(context, request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool _isDownloadable(String url) {
    final cleanUrl = url.split('?').first.toLowerCase();
    final lowercaseUrl = url.toLowerCase();

    if (lowercaseUrl.startsWith('blob:') || lowercaseUrl.startsWith('data:')) {
      return true;
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
    final canBack = await _webViewController.canGoBack();
    final canForward = await _webViewController.canGoForward();
    if (mounted) {
      setState(() {
        _canGoBack = canBack;
        _canGoForward = canForward;
      });
    }
  }

  void _navigateToUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return;

    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      if (url.contains('.') && !url.contains(' ')) {
        url = 'https://$url';
      } else {
        // Perform Google search
        url = 'https://google.com/search?q=${Uri.encodeComponent(url)}';
      }
    }
    
    setState(() {
      _isHome = false;
    });
    _webViewController.loadRequest(Uri.parse(url));
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

  Widget _buildHomeDashboard(BuildContext context, SettingsProvider settings) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accentColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          // Branding Banner
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
                  activeColor: accentColor,
                  onChanged: (val) {
                    triggerHaptic(settings);
                    setState(() {
                      _isSnifferEnabled = val;
                    });
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 30),

          // Quick Ports / Bookmarks
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

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          triggerHaptic(settings);
          setState(() {
            _isHome = false;
          });
          _navigateToUrl(url);
        },
        borderRadius: BorderRadius.circular(16),
        child: GlassCard(
          borderRadius: 16,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          isDarkMode: isDark,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          titleSpacing: 0,
          title: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            child: Row(
              children: [
                // 1. Browser address textfield input
                Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: 40,
                    decoration: BoxDecoration(
                      color: isDark ? AppTheme.glassBg : AppTheme.lightGlassBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: _isFocused
                            ? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue)
                            : (isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder),
                        width: 1.0,
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
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: TextField(
                      controller: _urlController,
                      focusNode: _focusNode,
                      style: TextStyle(
                        color: textClr,
                        fontSize: 13,
                      ),
                      decoration: InputDecoration(
                        icon: Icon(
                          _isHome ? Icons.search : Icons.language,
                          color: _isFocused
                              ? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue)
                              : (isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary),
                          size: 16,
                        ),
                        suffixIcon: _urlController.text.isNotEmpty
                            ? IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                icon: Icon(
                                  Icons.clear, 
                                  size: 16, 
                                  color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary
                                ),
                                onPressed: () {
                                  triggerHaptic(settings);
                                  _urlController.clear();
                                  setState(() {});
                                },
                              )
                            : null,
                        hintText: isRtl ? 'ابحث أو ادخل الرابط...' : 'SEARCH OR SCAN SIGNAL...',
                        hintStyle: TextStyle(
                          color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                          fontSize: 11,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      onSubmitted: _navigateToUrl,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Navigation controls
                if (!_isHome) ...[
                  IconButton(
                    icon: Icon(Icons.home_outlined, size: 18, color: textClr),
                    onPressed: () {
                      triggerHaptic(settings);
                      setState(() {
                        _isHome = true;
                        _urlController.clear();
                      });
                      _webViewController.loadRequest(Uri.parse('about:blank'));
                    },
                  ),
                  IconButton(
                    icon: Icon(Icons.arrow_back_ios_new, size: 15, color: _canGoBack ? textClr : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted)),
                    onPressed: _canGoBack
                        ? () {
                            triggerHaptic(settings);
                            _webViewController.goBack();
                          }
                        : null,
                  ),
                  IconButton(
                    icon: Icon(Icons.arrow_forward_ios, size: 15, color: _canGoForward ? textClr : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted)),
                    onPressed: _canGoForward
                        ? () {
                            triggerHaptic(settings);
                            _webViewController.goForward();
                          }
                        : null,
                  ),
                  IconButton(
                    icon: Icon(Icons.refresh, size: 17, color: textClr),
                    onPressed: () {
                      triggerHaptic(settings);
                      _webViewController.reload();
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              // Loading Progress line
              if (_isLoading && !_isHome)
                LinearProgressIndicator(
                  value: _loadingProgress,
                  minHeight: 2.0,
                  backgroundColor: Colors.transparent,
                  color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                ),
              Expanded(
                child: _isHome
                    ? _buildHomeDashboard(context, settings)
                    : WebViewWidget(controller: _webViewController),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
