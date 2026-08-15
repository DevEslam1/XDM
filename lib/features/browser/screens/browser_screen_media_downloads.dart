part of 'browser_screen.dart';

/// Media sniffing UI, quality picker, JS/CSS injector, offline save,
/// YouTube grab, and the download FAB.
mixin _MediaDownloadsMixin on _BrowserScreenStateBase {
  @override
  void _showLongPressSheet(
    BuildContext context,
    String url,
    String type, {
    String text = '',
    String? tabId,
  }) {
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final activeTab = _tabs[_currentTabIndex];
    final tab = tabId == null
        ? activeTab
        : _tabs.firstWhere(
            (t) => t.id == tabId,
            orElse: () => activeTab,
          );

    final hasMultipleQualities =
        _detectedMediaSources[tab.id]?.isNotEmpty ?? false;

    final discovered = (_detectedMediaSources[tab.id] ?? [])
        .map(MediaSourceItem.fromMap)
        .toList();
    final sources = filterSourcesForTarget(discovered, url, type);

    var cleanUrl = url.trim();
    if (cleanUrl.isNotEmpty) {
      if (!cleanUrl.startsWith('http://') &&
          !cleanUrl.startsWith('https://') &&
          !cleanUrl.startsWith('magnet:') &&
          !cleanUrl.startsWith('file:')) {
        if (cleanUrl.startsWith('//')) {
          cleanUrl = 'https:$cleanUrl';
        } else if (cleanUrl.startsWith('/')) {
          final baseUri = Uri.tryParse(tab.url);
          if (baseUri != null && baseUri.host.isNotEmpty) {
            cleanUrl = '${baseUri.scheme}://${baseUri.host}$cleanUrl';
          } else {
            cleanUrl = 'https://$cleanUrl';
          }
        } else {
          cleanUrl = 'https://$cleanUrl';
        }
      }
    }

    if (cleanUrl.isEmpty) return;

    final now = DateTime.now();
    if (_lastLongPressSheetUrl == cleanUrl &&
        _lastLongPressSheetAt != null &&
        now.difference(_lastLongPressSheetAt!) <
            const Duration(milliseconds: 600)) {
      return;
    }
    _lastLongPressSheetUrl = cleanUrl;
    _lastLongPressSheetAt = now;

    final isWebUrl =
        cleanUrl.startsWith('http://') || cleanUrl.startsWith('https://');

    // Plain link long-press → lightweight navigation sheet.
    // Media/file long-press → BrowserDownloadSheet (download-forward UI).
    if (type == 'link') {
      LinkOptionsSheet.show(
        context,
        cleanUrl,
        onOpen: () => _navigateToUrl(cleanUrl),
        onOpenInNewTab: () {
          _openInNewTab(
            cleanUrl,
            isIncognito: tab.isIncognito,
            switchToTab: true,
            origin: TabOrigin.userDirect,
          );
          _saveTabs();
        },
        onOpenInBackground: () =>
            _openInBackgroundTab(cleanUrl, isIncognito: tab.isIncognito),
        onOpenInIncognito: () {
          _openInNewTab(
            cleanUrl,
            isIncognito: true,
            switchToTab: true,
            origin: TabOrigin.userDirect,
          );
          _saveTabs();
        },
        onDownload: () => _showInterceptionSheet(context, cleanUrl),
      );
      return;
    }

    // Media / file long-press → BrowserDownloadSheet.
    BrowserDownloadSheet.show(
      context,
      url,
      type: type,
      text: text,
      downloadPageUrl: tab.isHome ? null : tab.url,
      onQuality: hasMultipleQualities
          ? () => _showQualityPicker(tab.id, fallbackUrl: url)
          : null,
      onOpen: isWebUrl ? () => _navigateToUrl(cleanUrl) : null,
      onOpenInBackground: isWebUrl
          ? () => _openInBackgroundTab(cleanUrl, isIncognito: tab.isIncognito)
          : null,
      onOpenInNewTab: isWebUrl
          ? () => _openInNewTab(cleanUrl,
              isIncognito: tab.isIncognito, switchToTab: true)
          : null,
      onOpenInIncognito: isWebUrl
          ? () => _openInNewTab(cleanUrl, isIncognito: true, switchToTab: true)
          : null,
      sources: sources,
    );
  }

  @override
  void _showInterceptionSheet(BuildContext context, String downloadUrl) {
    final now = DateTime.now();
    if (_lastInterceptedUrl == downloadUrl &&
        _lastInterceptedTime != null &&
        now.difference(_lastInterceptedTime!) < const Duration(seconds: 2)) {
      _log.info(
          '[Browser] Skipping duplicate interception sheet for: $downloadUrl');
      return;
    }
    _lastInterceptedUrl = downloadUrl;
    _lastInterceptedTime = now;

    final settings = _settings;
    triggerHaptic(settings);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final isMagnetSignal =
        downloadUrl.startsWith('magnet:') || isMagnetUrl(downloadUrl);
    if (isMagnetSignal) {
      AddDownloadDialog.show(context, prefilledUrl: downloadUrl);
      return;
    }
    final detected = BrowserDetector.detect(downloadUrl);
    final kindLabel =
        detected == null ? 'FILE' : detected.kind.name.toUpperCase();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        return Directionality(
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            child: DmxBackdropFilter(
              sigmaX: 15,
              sigmaY: 15,
              child: Container(
                decoration: BoxDecoration(
                  color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                      .withValues(alpha: 0.88),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                  border: Border(
                    top: BorderSide(
                      color: accent.withValues(alpha: 0.4),
                      width: 1.2,
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
                              color: accent.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            _PulsingIconBadge(
                              icon: Icons.radar_rounded,
                              color: accent,
                              isDark: isDark,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    L10n.of(
                                      context,
                                      'browser_intercepted_signal',
                                    ),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          color: accent,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 0.3,
                                          fontSize: 14,
                                        ),
                                  ),
                                  const SizedBox(height: 3),
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: accent.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(
                                            5,
                                          ),
                                        ),
                                        child: Text(
                                          kindLabel,
                                          style: TextStyle(
                                            color: accent,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.3,
                                            fontFamily: 'Space Grotesk',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        isRtl
                                            ? 'إشارة قابلة للتنزيل'
                                            : 'Downloadable stream',
                                        style: TextStyle(
                                          color: isDark
                                              ? AppTheme.textMuted
                                              : AppTheme.lightTextMuted,
                                          fontSize: 12,
                                          letterSpacing: 0.3,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        _CornerBracketBox(
                          color: accent,
                          isDark: isDark,
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.link_rounded,
                                  size: 14,
                                  color: accent.withValues(alpha: 0.7),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    downloadUrl,
                                    style: TextStyle(
                                      color: isDark
                                          ? AppTheme.textPrimary
                                          : AppTheme.lightTextPrimary,
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      height: 1.5,
                                    ),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(
                                    color: isDark
                                        ? AppTheme.glassBorder
                                        : AppTheme.lightGlassBorder,
                                  ),
                                  foregroundColor: isDark
                                      ? AppTheme.textSecondary
                                      : AppTheme.lightTextSecondary,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                ),
                                onPressed: () {
                                  Navigator.pop(sheetContext);
                                  if (_currentTabIndex >= 0 &&
                                      _currentTabIndex < _tabs.length) {
                                    final activeTab = _tabs[_currentTabIndex];
                                    _interceptor.addBypass(downloadUrl);
                                    activeTab.controller?.loadUrl(
                                      urlRequest:
                                          URLRequest(url: WebUri(downloadUrl)),
                                    );
                                  }
                                },
                                child: Text(
                                  L10n.of(context, 'browser_continue_browsing'),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: NeonGlowButton(
                                isFilled: true,
                                color: accent,
                                onPressed: () {
                                  Navigator.pop(sheetContext);
                                  _startDirectDownload(downloadUrl);
                                },
                                text: L10n.of(context, 'browser_download_btn'),
                                icon: Icons.download_rounded,
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

  void _showQualityPicker(String tabId, {String? fallbackUrl}) {
    final settings = _settings;
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final detectedSources = _detectedMediaSources[tabId] ?? [];

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
                color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                    .withValues(alpha: 0.95),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border(
                  top: BorderSide(
                    color: isDark
                        ? AppTheme.glassBorder
                        : AppTheme.lightGlassBorder,
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
                            color: (isDark
                                    ? AppTheme.textMuted
                                    : AppTheme.lightTextMuted)
                                .withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Icon(Icons.tune_rounded, color: accent, size: 20),
                          const SizedBox(width: 10),
                          Text(
                            L10n.of(context, 'browser_select_video_quality'),
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  color: accent,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.0,
                                  fontSize: 14,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (detectedSources.isNotEmpty) ...[
                        ...detectedSources.map((src) {
                          final label = src['label'] as String? ??
                              L10n.of(context, 'browser_alternative_stream');
                          final srcUrl = src['src'] as String? ?? '';
                          return _buildQualityTile(
                            context,
                            label,
                            srcUrl,
                            isDark,
                            settings,
                          );
                        }),
                      ] else ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Text(
                            L10n.of(
                              context,
                              'browser_no_alternative_streams',
                            ),
                            style: TextStyle(
                              color: accent,
                              fontSize: 13,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                      ],
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

  void _showDetectedMediaSheet(BuildContext context, String tabId) {
    final settings = _settings;
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final detectedSources = _detectedMediaSources[tabId] ?? [];
    final downloadPageUrl =
        _tabs.where((t) => t.id == tabId).map((t) => t.url).firstOrNull;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: DmxBackdropFilter(
            sigmaX: 15,
            sigmaY: 15,
            child: Container(
              decoration: BoxDecoration(
                color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                    .withValues(alpha: 0.95),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border(
                  top: BorderSide(
                    color: accent.withValues(alpha: 0.4),
                    width: 1.2,
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
                            color: accent.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          _PulsingIconBadge(
                            icon: Icons.sensors_rounded,
                            color: accent,
                            isDark: isDark,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  L10n.of(context, 'browser_detected_media'),
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        color: accent,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.5,
                                        fontSize: 14,
                                      ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${detectedSources.length} ${L10n.isRtl(context) ? "إشارة" : "streams detected"}',
                                  style: TextStyle(
                                    color: isDark
                                        ? AppTheme.textMuted
                                        : AppTheme.lightTextMuted,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.4,
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: detectedSources.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, i) {
                            final src = detectedSources[i];
                            final label = src['label'] as String? ??
                                '${L10n.of(context, 'browser_media_stream')} ${i + 1}';
                            final srcUrl = src['src'] as String? ?? '';
                            final isAudio = label.toLowerCase().contains(
                                  'audio',
                                );
                            final tileClr = isAudio
                                ? (isDark
                                    ? AppTheme.neonGreen
                                    : AppTheme.lightNeonGreen)
                                : accent;

                            return Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  final title = src['title'] as String?;
                                  final ext = src['ext'] as String?;
                                  String? filename;
                                  if (title != null && title.isNotEmpty) {
                                    filename =
                                        ext != null ? '$title.$ext' : title;
                                  }
                                  BrowserDownloadSheet.show(
                                    context,
                                    srcUrl,
                                    suggestedName: filename,
                                    type: isAudio ? 'audio' : 'video',
                                    onQuality: () => _showQualityPicker(
                                      tabId,
                                      fallbackUrl: srcUrl,
                                    ),
                                    downloadPageUrl: downloadPageUrl,
                                  );
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: tileClr.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: tileClr.withValues(alpha: 0.2),
                                      width: 0.7,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        isAudio
                                            ? Icons.audiotrack_rounded
                                            : Icons.play_circle_fill,
                                        color: tileClr,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              label,
                                              style: TextStyle(
                                                color: isDark
                                                    ? AppTheme.textPrimary
                                                    : AppTheme.lightTextPrimary,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              srcUrl,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: isDark
                                                    ? AppTheme.textMuted
                                                    : AppTheme.lightTextMuted,
                                                fontSize: 12,
                                                fontFamily: 'monospace',
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Icon(
                                        Icons.download_rounded,
                                        size: 16,
                                        color: tileClr,
                                      ),
                                    ],
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
          ),
        );
      },
    );
  }

  @override
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
            if (_currentTabIndex >= 0 && _currentTabIndex < _tabs.length) {
              _injectCustomJsCss(_tabs[_currentTabIndex]);
            }
          },
        );
      },
    );
  }

  @override
  Future<void> _injectCustomJsCss(BrowserTab tab) async {
    if (!mounted) return;
    await _scriptInjector.injectCustomJsCss(
      tab,
      customJs: _customJs,
      customCss: _customCss,
    );
  }

  @override
  Future<void> _savePageOffline(BrowserTab tab) async {
    if (tab.isHome) return;
    final settings = _settings;
    triggerHaptic(settings);
    try {
      final offlineTitle =
          mounted ? L10n.of(context, 'browser_offline_page') : 'Offline Page';
      String title = tab.title.isNotEmpty ? tab.title : offlineTitle;
      // Strip filesystem-illegal chars, control chars, newlines, and trailing
      // dots/spaces (Windows quirk). Collapse whitespace and cap length to
      // avoid path-length issues across platforms.
      title = title
          .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      title = title.replaceAll(RegExp(r'[. ]+$'), '');
      if (title.isEmpty) title = offlineTitle;
      if (title.length > 120) title = title.substring(0, 120);

      final path = settings.customDownloadPath?.isNotEmpty == true
          ? settings.customDownloadPath!
          : await PermissionService().defaultDownloadDirectory();

      String? webArchiveSavedPath;
      if (Platform.isAndroid && tab.controller != null) {
        try {
          final archivePath = p.join(path, '$title.mhtml');
          final res = await tab.controller
              ?.saveWebArchive(filePath: archivePath, autoname: false);
          if (res != null && res.isNotEmpty) {
            webArchiveSavedPath = res;
          }
        } catch (e, st) {
      LoggingService.logger('BrowserScreenMediaDownloads').warning('Operation failed', e, st);
    }
      }

      String fileName;
      String filePath;
      int size = 0;

      if (webArchiveSavedPath != null &&
          File(webArchiveSavedPath).existsSync()) {
        fileName = '$title.mhtml';
        filePath = webArchiveSavedPath;
        size = await File(webArchiveSavedPath).length();
      } else {
        fileName = '$title.html';
        filePath = p.join(path, fileName);
        String rawHtml = '';
        try {
          final result = await tab.controller?.evaluateJavascript(
            source: 'document.documentElement.outerHTML',
          );
          if (result is String) {
            rawHtml = result;
            if (rawHtml.isNotEmpty) {
              try {
                final decoded = jsonDecode(rawHtml);
                if (decoded is String) {
                  rawHtml = decoded;
                }
              } catch (e, st) {
      LoggingService.logger('BrowserScreenMediaDownloads').warning('Operation failed', e, st);
    }
            }
          }
        } catch (e) {
          // outerHTML fetch can fail or throw OOM on massive pages.
          Logger('browser_media_downloads')
              .warning('Failed to retrieve page HTML: $e');
        }

        if (rawHtml.isEmpty) {
          if (mounted) {
            final isRtl = L10n.isRtl(context);
            ThemedSnackbar.show(
              context,
              message: isRtl
                  ? 'تعذر حفظ الصفحة. قد تكون الصفحة كبيرة جدًا.'
                  : 'Could not save page. The page might be too large.',
              color: settings.isDarkMode
                  ? AppTheme.neonRed
                  : AppTheme.lightNeonRed,
              icon: Icons.error_outline,
              isDarkMode: settings.isDarkMode,
            );
          }
          return;
        }
        final file = File(filePath);
        await file.writeAsString(rawHtml);
        size = utf8.encode(rawHtml).length;
      }

      final id = DateTime.now().millisecondsSinceEpoch.toString();

      final task = DownloadTask(
        id: id,
        fileName: fileName, // Fix: Use the evaluated fileName (supports .mhtml)
        url: tab.url,
        fileSize: size,
        downloadedBytes: size,
        category: 'Document',
        status: DownloadStatus.completed,
        savePath: path,
        localFilePath: filePath,
        tempFilePath: '',
        threadCount: 1,
        chunks: [1.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        completedAt: DateTime.now(),
      );

      if (!mounted) return;
      final db = context.read<DatabaseService>();
      await db.saveTask(task);

      if (mounted) {
        await context.read<DownloadProvider>().load(
              pauseOrphanDownloads: false,
            );
        if (mounted) {
          ThemedSnackbar.show(
            context,
            message: '${L10n.of(context, 'browser_page_saved')} - $fileName',
            color: settings.isDarkMode
                ? AppTheme.neonGreen
                : AppTheme.lightNeonGreen,
            icon: Icons.check_circle_outline,
            isDarkMode: settings.isDarkMode,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ThemedSnackbar.show(
          context,
          message: '${L10n.of(context, 'browser_page_save_error')}: $e',
          color: settings.isDarkMode ? AppTheme.neonRed : AppTheme.lightNeonRed,
          icon: Icons.error_outline,
          isDarkMode: settings.isDarkMode,
        );
      }
    }
  }

  @override
  Future<void> _handleYouTubeGrab(
    BrowserTab activeTab,
    SettingsProvider settings,
  ) async {
    triggerHaptic(settings);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final tabUrl = activeTab.url;

    final isPlaylist = YoutubeService.isPlaylistUrl(tabUrl);
    final isVideo = YoutubeService.isYoutubeVideoUrl(tabUrl);
    final isMixed = isPlaylist && isVideo;

    if (isMixed) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: Text(
            isRtl ? 'ماذا تريد تحميل؟' : 'What do you want to download?',
            style: TextStyle(
                color: isDark ? Colors.white : Colors.black87,
                fontSize: 16,
                fontWeight: FontWeight.bold),
          ),
          content: Text(
            isRtl
                ? 'هذا الرابط يحتوي على فيديو وقائمة تشغيل.'
                : 'This link contains both a single video and a playlist.',
            style: TextStyle(
                color: isDark ? Colors.white70 : Colors.black54, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'video'),
              child: Text(isRtl ? 'فيديو واحد فقط' : 'Single video',
                  style: const TextStyle(
                      color: Colors.blue, fontWeight: FontWeight.bold)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'playlist'),
              child: Text(isRtl ? 'قائمة التشغيل كاملة' : 'Entire playlist',
                  style: const TextStyle(
                      color: Colors.red, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (choice == 'playlist') {
        final result = await YoutubePlaylistSheet.show(context, tabUrl);
        if (!mounted) return;
        if (result != null) {
          ThemedSnackbar.show(
            context,
            message: isRtl
                ? 'تمت إضافة ${result.selectedVideos.length} فيديو إلى قائمة الانتظار'
                : '${result.selectedVideos.length} videos enqueued from "${result.playlistTitle}"',
            color: AppTheme.neonGreen,
            icon: Icons.playlist_add_check,
            isDarkMode: isDark,
          );
        }
        return;
      } else if (choice != 'video') {
        return;
      }
    } else if (isPlaylist) {
      final result = await YoutubePlaylistSheet.show(context, tabUrl);
      if (!mounted) return;
      if (result != null) {
        ThemedSnackbar.show(
          context,
          message: isRtl
              ? 'تمت إضافة ${result.selectedVideos.length} فيديو إلى قائمة الانتظار'
              : '${result.selectedVideos.length} videos enqueued from "${result.playlistTitle}"',
          color: AppTheme.neonGreen,
          icon: Icons.playlist_add_check,
          isDarkMode: isDark,
        );
      }
      return;
    }

    final stream = await YoutubeQualitySheet.show(context, tabUrl);
    if (!mounted) return;
    if (stream != null) {
      final title = stream['title'] as String? ?? 'YouTube video';
      final ext = stream['ext'] as String? ?? 'mp4';
      _startDirectDownload(
        stream['src'] as String,
        suggestedName: '$title.$ext',
        type: 'video',
        audioUrl: stream['audioSrc'] as String?,
        videoSize: stream['videoSize'] as int?,
        audioSize: stream['audioSize'] as int?,
      );
    }
  }

  @override
  void _onDownloadProviderChanged() {
    final urlToLoad = _downloadProvider?.browserUrlToLoad;
    if (urlToLoad != null) {
      _downloadProvider?.clearBrowserUrlToLoad();
      _navigateToUrl(urlToLoad);
    }
  }

  @override
  Widget _buildDownloadFab(BuildContext context, SettingsProvider settings) {
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    // Bug #9 fix: _buildDownloadFab can be called during tab transitions when
    // _tabs is empty or _currentTabIndex is out of bounds. Return an invisible
    // widget instead of crashing with a RangeError.
    if (_tabs.isEmpty ||
        _currentTabIndex < 0 ||
        _currentTabIndex >= _tabs.length) {
      return const SizedBox.shrink();
    }
    final activeTab = _tabs[_currentTabIndex];

    if (_isYoutubeHost(activeTab.url)) {
      return _buildDefaultDownloadFab(isDark, accent, settings, activeTab);
    }

    if (_mediaScanFailed[activeTab.id] == true) {
      return _SignalFab(
        heroTag: 'download_fab_${activeTab.id}',
        color: Colors.orange,
        icon: Icons.refresh_rounded,
        label: 'Scan failed (retry)',
        pulse: false,
        isDark: isDark,
        onPressed: () {
          triggerHaptic(settings);
          _scanPageMedia(activeTab);
        },
      );
    }

    final detectedSources = _detectedMediaSources[activeTab.id] ?? [];
    final isPlaylist = _detectedPlaylistUrls.containsKey(activeTab.id);
    final playlistCount = _detectedPlaylistUrls[activeTab.id] ?? 0;

    if (isPlaylist) {
      return _SignalFab(
        heroTag: 'download_fab_${activeTab.id}',
        color: Colors.red,
        icon: Icons.playlist_play_rounded,
        label: 'Playlist${playlistCount > 0 ? ' ($playlistCount)' : ''}',
        pulse: true,
        isDark: isDark,
        onPressed: () async {
          triggerHaptic(settings);
          final result =
              await YoutubePlaylistSheet.show(context, activeTab.url);
          if (result != null && context.mounted) {
            ThemedSnackbar.show(
              context,
              message:
                  '${result.selectedVideos.length} videos enqueued from "${result.playlistTitle}"',
              color: AppTheme.neonGreen,
              icon: Icons.playlist_add_check,
              isDarkMode: isDark,
            );
          }
        },
      );
    }

    if (YoutubeService.isExtractableMediaUrl(activeTab.url) &&
        detectedSources.isNotEmpty) {
      return _SignalFab(
        heroTag: 'download_fab_${activeTab.id}',
        color: Colors.red,
        icon: Icons.play_circle_filled,
        label: detectedSources.length > 1
            ? 'Media (${detectedSources.length})'
            : 'Media',
        pulse: true,
        isDark: isDark,
        onPressed: () async {
          triggerHaptic(settings);
          if (detectedSources.length > 1) {
            _showDetectedMediaSheet(context, activeTab.id);
          } else {
            final stream =
                await YoutubeQualitySheet.show(context, activeTab.url);
            if (stream != null && context.mounted) {
              final title = stream['title'] as String? ?? 'Media video';
              final ext = stream['ext'] as String? ?? 'mp4';
              _startDirectDownload(
                stream['src'] as String,
                suggestedName: '$title.$ext',
                type: 'video',
                audioUrl: stream['audioSrc'] as String?,
                videoSize: stream['videoSize'] as int?,
                audioSize: stream['audioSize'] as int?,
              );
            }
          }
        },
      );
    }

    if (YoutubeService.isYoutubeVideoUrl(activeTab.url) &&
        _ytDetectionFailed.containsKey(activeTab.url)) {
      return _SignalFab(
        heroTag: 'download_fab_${activeTab.id}',
        color: Colors.red.withValues(alpha: 0.6),
        icon: Icons.refresh_rounded,
        label: 'YouTube (retry)',
        pulse: false,
        isDark: isDark,
        onPressed: () async {
          triggerHaptic(settings);
          setState(() {
            _ytDetectionFailed.remove(activeTab.url);
          });
          _scanPageMedia(activeTab);
        },
      );
    }

    return _SignalFab(
      heroTag: 'download_fab_${activeTab.id}',
      color: accent,
      icon: Icons.download_rounded,
      label: detectedSources.length > 1
          ? 'Downloads (${detectedSources.length})'
          : 'Download',
      pulse: detectedSources.isNotEmpty,
      isDark: isDark,
      onPressed: () {
        triggerHaptic(settings);
        if (detectedSources.length > 1) {
          _showDetectedMediaSheet(context, activeTab.id);
        } else {
          final url = detectedSources.isNotEmpty
              ? detectedSources.first['src']
              : _detectedDownloadUrls[activeTab.id];
          if (url == null) return;
          final title = detectedSources.isNotEmpty
              ? detectedSources.first['title'] as String?
              : null;
          final ext = detectedSources.isNotEmpty
              ? detectedSources.first['ext'] as String?
              : null;
          String? filename;
          if (title != null && title.isNotEmpty) {
            filename = ext != null ? '$title.$ext' : title;
          }
          BrowserDownloadSheet.show(
            context,
            url,
            suggestedName: filename,
            onQuality: () => _showQualityPicker(activeTab.id, fallbackUrl: url),
            downloadPageUrl: activeTab.isHome ? null : activeTab.url,
          );
        }
      },
    );
  }

  Widget _buildDefaultDownloadFab(
    bool isDark,
    Color accent,
    SettingsProvider settings,
    BrowserTab activeTab,
  ) {
    final url = _detectedDownloadUrls[activeTab.id];
    return _SignalFab(
      heroTag: 'download_fab_${activeTab.id}',
      color: accent,
      icon: Icons.download_rounded,
      label: 'Download',
      pulse: false,
      isDark: isDark,
      onPressed: () {
        triggerHaptic(settings);
        if (url != null) {
          BrowserDownloadSheet.show(
            context,
            url,
            onQuality: () => _showQualityPicker(activeTab.id, fallbackUrl: url),
            downloadPageUrl: activeTab.isHome ? null : activeTab.url,
          );
        }
      },
    );
  }

  @override
  Future<void> _startDirectDownload(
    String url, {
    String? suggestedName,
    String? type,
    String? downloadPageUrl,
    String? audioUrl,
    int? videoSize,
    int? audioSize,
  }) async {
    final settingsProvider = _settings;
    final isRtl = L10n.isRtl(context);
    final isDark = settingsProvider.isDarkMode;

    final result = await _interceptor.startDirectDownload(
      url,
      suggestedName: suggestedName,
      type: type,
      downloadPageUrl: downloadPageUrl,
      audioUrl: audioUrl,
      videoSize: videoSize,
      audioSize: audioSize,
    );

    if (!mounted) return;

    switch (result.status) {
      case InterceptDownloadStatus.alreadyCompleted:
        ThemedSnackbar.show(context,
            message: isRtl
                ? 'هذا التنزيل مكتمل بالفعل'
                : 'This download is already completed.',
            color: AppTheme.neonGreen,
            icon: Icons.check_circle_outline,
            isDarkMode: isDark);
      case InterceptDownloadStatus.alreadyInProgress:
        ThemedSnackbar.show(context,
            message: isRtl
                ? 'هذا التنزيل قيد التشغيل بالفعل'
                : 'This download is already in progress.',
            color: AppTheme.neonBlue,
            icon: Icons.info_outline,
            isDarkMode: isDark);
      case InterceptDownloadStatus.resumed:
        ThemedSnackbar.show(context,
            message: isRtl ? 'تم استئناف التنزيل' : 'Download resumed.',
            color: AppTheme.neonBlue,
            icon: Icons.play_arrow,
            isDarkMode: isDark);
      case InterceptDownloadStatus.queued:
        ThemedSnackbar.show(context,
            message: isRtl
                ? 'تم إنشاء الاتصال. القنوات متصلة.'
                : 'Download queued successfully.',
            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            icon: Icons.rocket_launch_outlined,
            isDarkMode: isDark);
      case InterceptDownloadStatus.failed:
        ThemedSnackbar.show(context,
            message: result.errorMessage ?? 'Download failed.',
            color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
            icon: Icons.error_outline,
            isDarkMode: isDark);
      case InterceptDownloadStatus.skipped:
        break;
    }
  }
}
