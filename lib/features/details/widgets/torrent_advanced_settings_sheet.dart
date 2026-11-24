import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/domain/torrent_models.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';

class TorrentAdvancedSettingsSheet extends StatefulWidget {
  final int torrentId;

  const TorrentAdvancedSettingsSheet({
    super.key,
    required this.torrentId,
  });

  static Future<void> show(BuildContext context, int torrentId) {
    return showDmxModalBottomSheet<void>(
      context: context,
      builder: (ctx) => TorrentAdvancedSettingsSheet(torrentId: torrentId),
    );
  }

  @override
  State<TorrentAdvancedSettingsSheet> createState() =>
      _TorrentAdvancedSettingsSheetState();
}

class _TorrentAdvancedSettingsSheetState
    extends State<TorrentAdvancedSettingsSheet> {
  final TextEditingController _webSeedController = TextEditingController();
  final TextEditingController _proxyHostController = TextEditingController();
  final TextEditingController _proxyPortController = TextEditingController();
  final TextEditingController _proxyUserController = TextEditingController();
  final TextEditingController _proxyPassController = TextEditingController();

  ProxyType _selectedProxyType = ProxyType.none;
  bool _obscurePassword = true;

  String? _selectedCertPath;
  String? _selectedKeyPath;

  bool _isSavingProxy = false;
  bool _isSavingSsl = false;

  @override
  void initState() {
    super.initState();
    SettingsProvider? settings;
    try {
      settings = SettingsProvider.instance;
    } catch (_) {}
    if (settings != null) {
      _selectedProxyType = ProxyType.fromString(settings.proxyType);
      _proxyHostController.text = settings.proxyHost;
      _proxyPortController.text = settings.proxyPort.toString();
      _proxyUserController.text = settings.proxyUsername ?? '';
      _proxyPassController.text = settings.proxyPassword ?? '';
      _selectedCertPath = settings.sslCertPath;
      _selectedKeyPath = settings.sslKeyPath;
    }
  }

  @override
  void dispose() {
    _webSeedController.dispose();
    _proxyHostController.dispose();
    _proxyPortController.dispose();
    _proxyUserController.dispose();
    _proxyPassController.dispose();
    super.dispose();
  }

  void _showSnack(String message, {required bool isError}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isError
        ? (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
        : (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: bg,
      ),
    );
  }

  Future<void> _addWebSeed(DownloadProvider provider) async {
    final url = _webSeedController.text.trim();
    if (url.isEmpty ||
        (!url.startsWith('http://') &&
            !url.startsWith('https://') &&
            !url.startsWith('ftp://'))) {
      _showSnack('Please enter a valid HTTP/HTTPS/FTP URL', isError: true);
      return;
    }

    provider.addWebSeed(url, widget.torrentId);
    _webSeedController.clear();
    setState(() {});
    _showSnack('Web seed added', isError: false);
  }

  Future<void> _applyProxy(DownloadProvider provider) async {
    final host = _proxyHostController.text.trim();
    final port = int.tryParse(_proxyPortController.text.trim()) ?? 1080;

    if (_selectedProxyType != ProxyType.none && host.isEmpty) {
      _showSnack('Please enter a valid proxy host', isError: true);
      return;
    }

    setState(() => _isSavingProxy = true);
    try {
      await provider.applyProxySettings(
        host: host,
        port: port,
        type: _selectedProxyType,
        username: _proxyUserController.text.trim().isNotEmpty
            ? _proxyUserController.text.trim()
            : null,
        password: _proxyPassController.text.isNotEmpty
            ? _proxyPassController.text
            : null,
      );
      if (mounted) {
        _showSnack('Proxy settings applied successfully', isError: false);
      }
    } catch (e) {
      if (mounted) {
        _showSnack('Failed to apply proxy: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isSavingProxy = false);
    }
  }

  Future<void> _pickCertFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pem', 'crt', 'cer'],
    );
    if (result.isNotEmpty && result.single.path != null) {
      setState(() {
        _selectedCertPath = result.single.path;
      });
    }
  }

  Future<void> _pickKeyFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pem', 'key'],
    );
    if (result.isNotEmpty && result.single.path != null) {
      setState(() {
        _selectedKeyPath = result.single.path;
      });
    }
  }

  Future<void> _applySsl(DownloadProvider provider) async {
    if (_selectedCertPath == null || _selectedKeyPath == null) {
      _showSnack(
        'Please select both a certificate and a private key',
        isError: true,
      );
      return;
    }

    setState(() => _isSavingSsl = true);
    try {
      await provider.applySslSettings(
        certPath: _selectedCertPath!,
        privateKeyPath: _selectedKeyPath!,
      );
      if (mounted) {
        _showSnack('SSL certificates applied successfully', isError: false);
      }
    } catch (e) {
      if (mounted) {
        _showSnack('Failed to apply SSL certificates: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isSavingSsl = false);
    }
  }

  InputDecoration _fieldDecoration({
    required bool isDark,
    required Color focusColor,
    String? labelText,
    String? hintText,
    Widget? suffixIcon,
  }) {
    final borderClr = AppTheme.hairlineBorder(isDark);
    final fillClr = AppTheme.surfaceColor(isDark, elevated: false);
    final mutedClr = AppTheme.textMutedOf(isDark);
    final secClr = AppTheme.textSecondaryOf(isDark);

    return InputDecoration(
      labelText: labelText,
      labelStyle: TextStyle(
        fontFamily: AppTheme.fontBody,
        fontSize: 12,
        color: secClr,
      ),
      hintText: hintText,
      hintStyle: TextStyle(
        fontFamily: AppTheme.fontBody,
        fontSize: 12,
        color: mutedClr.withValues(alpha: 0.7),
      ),
      filled: true,
      fillColor: fillClr,
      isDense: true,
      suffixIcon: suffixIcon,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        borderSide: BorderSide(color: borderClr, width: 0.8),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        borderSide: BorderSide(color: borderClr, width: 0.8),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        borderSide: BorderSide(color: focusColor, width: 1.2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.read<DownloadProvider>();
    final settings = context.watch<SettingsProvider>();
    final webSeeds = context.select<DownloadProvider, List<String>>(
      (p) => p.getWebSeeds(widget.torrentId),
    );

    final blue = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final cyan = isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan;
    final amber = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    final green = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final red = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final textClr = AppTheme.textPrimaryOf(isDark);
    final secClr = AppTheme.textSecondaryOf(isDark);
    final mutedClr = AppTheme.textMutedOf(isDark);
    final hairline = AppTheme.hairlineBorder(isDark);
    final sheetSurface = AppTheme.sheetSurface(isDark);

    return DmxSheetContainer(
      scrollable: false,
      maxHeightFraction: 0.9,
      isDark: isDark,
      accentColor: blue,
      padding: EdgeInsets.zero,
      header: DmxSheetHeader(
        title: 'Advanced Torrent Controls',
        subtitle: 'Web seeds, proxy tunnel & SSL private trackers',
        icon: Icons.tune_rounded,
        accentColor: blue,
        isDark: isDark,
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          DmxTokens.sheetHorizontalPadding,
          14,
          DmxTokens.sheetHorizontalPadding,
          24,
        ),
        children: [
          // =================================================================
          // SECTION A: Web Seeds (HTTP/FTP)
          // =================================================================
          DmxSheetSection(
            title: 'Web Seeds (HTTP/FTP)',
            accentColor: cyan,
            isDark: isDark,
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: cyan.withValues(alpha: isDark ? 0.14 : 0.10),
                borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
              ),
              child: Text(
                '${webSeeds.length}',
                style: AppTheme.dataStyle(
                  isDark: isDark,
                  size: 11,
                  color: cyan,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add HTTP/FTP mirror URLs to accelerate download speed for this torrent.',
                  style: TextStyle(
                    fontFamily: AppTheme.fontBody,
                    fontSize: 12,
                    height: 1.4,
                    color: secClr,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _webSeedController,
                        style: TextStyle(
                          fontFamily: AppTheme.fontBody,
                          fontSize: 13,
                          color: textClr,
                        ),
                        decoration: _fieldDecoration(
                          isDark: isDark,
                          focusColor: cyan,
                          hintText: 'https://example.com/file.iso',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => _addWebSeed(provider),
                      icon: const Icon(Icons.add_rounded, size: 17),
                      label: const Text(
                        'Add',
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 44),
                        backgroundColor: cyan,
                        foregroundColor: AppTheme.inkOn(cyan),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(DmxTokens.radiusMd),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Attached Web Seeds (${webSeeds.length})',
                  style: TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: textClr,
                  ),
                ),
                const SizedBox(height: 6),
                if (webSeeds.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      'No web seeds currently attached to this torrent.',
                      style: TextStyle(
                        fontFamily: AppTheme.fontBody,
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: mutedClr,
                      ),
                    ),
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: webSeeds.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, thickness: 0.8, color: hairline),
                    itemBuilder: (ctx, idx) {
                      final seed = webSeeds[idx];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.link_rounded,
                          size: 18,
                          color: cyan,
                        ),
                        title: Text(
                          seed,
                          style: TextStyle(
                            fontFamily: AppTheme.fontBody,
                            fontSize: 12,
                            color: textClr,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                            color: red,
                          ),
                          onPressed: () {
                            provider.removeWebSeed(seed, widget.torrentId);
                            setState(() {});
                          },
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // =================================================================
          // SECTION B: Proxy Configuration (Session-level)
          // =================================================================
          DmxSheetSection(
            title: 'Proxy Configuration (Session-level)',
            accentColor: amber,
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Configure a proxy tunnel for all torrent peer traffic and tracker announces.',
                  style: TextStyle(
                    fontFamily: AppTheme.fontBody,
                    fontSize: 12,
                    height: 1.4,
                    color: secClr,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<ProxyType>(
                  initialValue: _selectedProxyType,
                  dropdownColor: sheetSurface,
                  style: TextStyle(
                    fontFamily: AppTheme.fontBody,
                    fontSize: 13,
                    color: textClr,
                  ),
                  decoration: _fieldDecoration(
                    isDark: isDark,
                    focusColor: amber,
                    labelText: 'Proxy Protocol',
                  ),
                  items: ProxyType.values.map((type) {
                    return DropdownMenuItem<ProxyType>(
                      value: type,
                      child: Text(type.displayName),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _selectedProxyType = val);
                    }
                  },
                ),
                if (_selectedProxyType != ProxyType.none) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _proxyHostController,
                          style: TextStyle(
                            fontFamily: AppTheme.fontBody,
                            fontSize: 13,
                            color: textClr,
                          ),
                          decoration: _fieldDecoration(
                            isDark: isDark,
                            focusColor: amber,
                            labelText: 'Host / IP',
                            hintText: '127.0.0.1',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _proxyPortController,
                          keyboardType: TextInputType.number,
                          style: TextStyle(
                            fontFamily: AppTheme.fontBody,
                            fontSize: 13,
                            color: textClr,
                          ),
                          decoration: _fieldDecoration(
                            isDark: isDark,
                            focusColor: amber,
                            labelText: 'Port',
                            hintText: '1080',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _proxyUserController,
                          style: TextStyle(
                            fontFamily: AppTheme.fontBody,
                            fontSize: 13,
                            color: textClr,
                          ),
                          decoration: _fieldDecoration(
                            isDark: isDark,
                            focusColor: amber,
                            labelText: 'Username (optional)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _proxyPassController,
                          obscureText: _obscurePassword,
                          style: TextStyle(
                            fontFamily: AppTheme.fontBody,
                            fontSize: 13,
                            color: textClr,
                          ),
                          decoration: _fieldDecoration(
                            isDark: isDark,
                            focusColor: amber,
                            labelText: 'Password (optional)',
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_rounded
                                    : Icons.visibility_off_rounded,
                                size: 18,
                                color: mutedClr,
                              ),
                              onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed:
                        _isSavingProxy ? null : () => _applyProxy(provider),
                    icon: _isSavingProxy
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppTheme.inkOn(amber),
                            ),
                          )
                        : const Icon(Icons.check_rounded, size: 18),
                    label: const Text(
                      'Apply Proxy Settings',
                      style: TextStyle(
                        fontFamily: AppTheme.fontDisplay,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 46),
                      backgroundColor: amber,
                      foregroundColor: AppTheme.inkOn(amber),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // =================================================================
          // SECTION C: SSL / Private Trackers (Session-level)
          // =================================================================
          DmxSheetSection(
            title: 'SSL / Private Trackers (Session-level)',
            accentColor: green,
            isDark: isDark,
            trailing: settings.isSslActive
                ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: green.withValues(alpha: isDark ? 0.16 : 0.12),
                      borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
                      border: Border.all(
                        color: green.withValues(alpha: 0.35),
                        width: 0.8,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle_rounded,
                            size: 12, color: green),
                        const SizedBox(width: 4),
                        Text(
                          'SSL Active',
                          style: TextStyle(
                            fontFamily: AppTheme.fontDisplay,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: green,
                          ),
                        ),
                      ],
                    ),
                  )
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Attach client certificates for SSL/TLS encrypted private trackers and secure swarms.',
                  style: TextStyle(
                    fontFamily: AppTheme.fontBody,
                    fontSize: 12,
                    height: 1.4,
                    color: secClr,
                  ),
                ),
                const SizedBox(height: 12),
                _buildFilePickerRow(
                  label: 'Certificate (.pem / .crt)',
                  filePath: _selectedCertPath,
                  icon: Icons.verified_user_outlined,
                  onPick: _pickCertFile,
                  onClear: () => setState(() => _selectedCertPath = null),
                  isDark: isDark,
                  accent: blue,
                ),
                const SizedBox(height: 10),
                _buildFilePickerRow(
                  label: 'Private Key (.pem / .key)',
                  filePath: _selectedKeyPath,
                  icon: Icons.key_outlined,
                  onPick: _pickKeyFile,
                  onClear: () => setState(() => _selectedKeyPath = null),
                  isDark: isDark,
                  accent: blue,
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _isSavingSsl ? null : () => _applySsl(provider),
                    icon: _isSavingSsl
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppTheme.inkOn(green),
                            ),
                          )
                        : const Icon(Icons.security_rounded, size: 18),
                    label: const Text(
                      'Apply SSL Certificates',
                      style: TextStyle(
                        fontFamily: AppTheme.fontDisplay,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 46),
                      backgroundColor: green,
                      foregroundColor: AppTheme.inkOn(green),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilePickerRow({
    required String label,
    required String? filePath,
    required IconData icon,
    required VoidCallback onPick,
    required VoidCallback onClear,
    required bool isDark,
    required Color accent,
  }) {
    final textClr = AppTheme.textPrimaryOf(isDark);
    final mutedClr = AppTheme.textMutedOf(isDark);
    final hairline = AppTheme.hairlineBorder(isDark);
    final hasFile = filePath != null && filePath.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor(isDark, elevated: false),
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        border: Border.all(color: hairline, width: 0.8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: AppTheme.fontBody,
                    fontSize: 11,
                    color: mutedClr,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  hasFile
                      ? filePath.split(RegExp(r'[\\/]')).last
                      : 'None selected',
                  style: TextStyle(
                    fontFamily: AppTheme.fontBody,
                    fontSize: 12.5,
                    fontWeight: hasFile ? FontWeight.w600 : FontWeight.normal,
                    color: hasFile ? textClr : mutedClr,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (hasFile)
            IconButton(
              icon: Icon(Icons.close_rounded, size: 16, color: mutedClr),
              onPressed: onClear,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
            ),
          const SizedBox(width: 4),
          OutlinedButton(
            onPressed: onPick,
            style: OutlinedButton.styleFrom(
              foregroundColor: accent,
              side:
                  BorderSide(color: accent.withValues(alpha: 0.45), width: 0.8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DmxTokens.radiusSm),
              ),
            ),
            child: const Text(
              'Browse',
              style: TextStyle(
                fontFamily: AppTheme.fontDisplay,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
