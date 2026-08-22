import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/torrent_models.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';

class TorrentAdvancedSettingsSheet extends StatefulWidget {
  final int torrentId;

  const TorrentAdvancedSettingsSheet({
    super.key,
    required this.torrentId,
  });

  static Future<void> show(BuildContext context, int torrentId) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
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

  Future<void> _addWebSeed(DownloadProvider provider) async {
    final url = _webSeedController.text.trim();
    if (url.isEmpty ||
        (!url.startsWith('http://') &&
            !url.startsWith('https://') &&
            !url.startsWith('ftp://'))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid HTTP/HTTPS/FTP URL'),
          backgroundColor: AppTheme.neonRed,
        ),
      );
      return;
    }

    provider.addWebSeed(url, widget.torrentId);
    _webSeedController.clear();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Web seed added'),
        backgroundColor: AppTheme.neonGreen,
      ),
    );
  }

  Future<void> _applyProxy(DownloadProvider provider) async {
    final host = _proxyHostController.text.trim();
    final port = int.tryParse(_proxyPortController.text.trim()) ?? 1080;

    if (_selectedProxyType != ProxyType.none && host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid proxy host'),
          backgroundColor: AppTheme.neonRed,
        ),
      );
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Proxy settings applied successfully'),
            backgroundColor: AppTheme.neonGreen,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to apply proxy: $e'),
            backgroundColor: AppTheme.neonRed,
          ),
        );
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
    if (result != null && result.files.single.path != null) {
      setState(() {
        _selectedCertPath = result.files.single.path;
      });
    }
  }

  Future<void> _pickKeyFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pem', 'key'],
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        _selectedKeyPath = result.files.single.path;
      });
    }
  }

  Future<void> _applySsl(DownloadProvider provider) async {
    if (_selectedCertPath == null || _selectedKeyPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select both a certificate and a private key'),
          backgroundColor: AppTheme.neonRed,
        ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('SSL certificates applied successfully'),
            backgroundColor: AppTheme.neonGreen,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to apply SSL certificates: $e'),
            backgroundColor: AppTheme.neonRed,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingSsl = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.read<DownloadProvider>();
    final settings = context.watch<SettingsProvider>();
    final webSeeds = context.select<DownloadProvider, List<String>>(
      (p) => p.getWebSeeds(widget.torrentId),
    );

    final bgClr = isDark ? const Color(0xFF1E222A) : Colors.white;
    final textClr = isDark ? Colors.white : Colors.black87;
    final mutedClr = isDark ? Colors.white70 : Colors.black54;
    final cardBg = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.03);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.08);

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (ctx, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: bgClr,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            children: [
              // Handle bar
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: mutedClr.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Header
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.tune, color: AppTheme.neonBlue, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Advanced Torrent Controls',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: textClr,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Scrollable Content
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  children: [
                    // =========================================================
                    // SECTION A: Web Seeds (HTTP/FTP)
                    // =========================================================
                    _buildSectionHeader(
                      icon: Icons.cloud_download_outlined,
                      title: 'Web Seeds (HTTP/FTP)',
                      color: AppTheme.neonCyan,
                      textClr: textClr,
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Add HTTP/FTP mirror URLs to accelerate download speed for this torrent.',
                            style: TextStyle(fontSize: 12, color: mutedClr),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _webSeedController,
                                  style:
                                      TextStyle(fontSize: 13, color: textClr),
                                  decoration: InputDecoration(
                                    hintText: 'https://example.com/file.iso',
                                    hintStyle: TextStyle(
                                      fontSize: 12,
                                      color: mutedClr.withValues(alpha: 0.6),
                                    ),
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide:
                                          BorderSide(color: borderColor),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                onPressed: () => _addWebSeed(provider),
                                icon: const Icon(Icons.add, size: 16),
                                label: const Text('Add'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      AppTheme.neonCyan.withValues(alpha: 0.2),
                                  foregroundColor: AppTheme.neonCyan,
                                  elevation: 0,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    side: BorderSide(
                                      color: AppTheme.neonCyan
                                          .withValues(alpha: 0.5),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Attached Web Seeds (${webSeeds.length})',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: textClr,
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (webSeeds.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                'No web seeds currently attached to this torrent.',
                                style: TextStyle(
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
                                  const Divider(height: 1),
                              itemBuilder: (ctx, idx) {
                                final seed = webSeeds[idx];
                                return ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(
                                    Icons.link,
                                    size: 18,
                                    color: AppTheme.neonCyan,
                                  ),
                                  title: Text(
                                    seed,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: textClr,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 18,
                                      color: AppTheme.neonRed,
                                    ),
                                    onPressed: () {
                                      provider.removeWebSeed(
                                        seed,
                                        widget.torrentId,
                                      );
                                      setState(() {});
                                    },
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // =========================================================
                    // SECTION B: Proxy Configuration (Session-level)
                    // =========================================================
                    _buildSectionHeader(
                      icon: Icons.shield_outlined,
                      title: 'Proxy Configuration (Session-level)',
                      color: AppTheme.neonAmber,
                      textClr: textClr,
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Configure a proxy tunnel for all torrent peer traffic and tracker announces.',
                            style: TextStyle(fontSize: 12, color: mutedClr),
                          ),
                          const SizedBox(height: 12),
                          // Proxy Type Dropdown
                          DropdownButtonFormField<ProxyType>(
                            initialValue: _selectedProxyType,
                            dropdownColor: bgClr,
                            style: TextStyle(fontSize: 13, color: textClr),
                            decoration: InputDecoration(
                              labelText: 'Proxy Protocol',
                              isDense: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
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
                                      fontSize: 13,
                                      color: textClr,
                                    ),
                                    decoration: InputDecoration(
                                      labelText: 'Host / IP',
                                      hintText: '127.0.0.1',
                                      isDense: true,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
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
                                      fontSize: 13,
                                      color: textClr,
                                    ),
                                    decoration: InputDecoration(
                                      labelText: 'Port',
                                      hintText: '1080',
                                      isDense: true,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
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
                                      fontSize: 13,
                                      color: textClr,
                                    ),
                                    decoration: InputDecoration(
                                      labelText: 'Username (optional)',
                                      isDense: true,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: _proxyPassController,
                                    obscureText: _obscurePassword,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: textClr,
                                    ),
                                    decoration: InputDecoration(
                                      labelText: 'Password (optional)',
                                      isDense: true,
                                      suffixIcon: IconButton(
                                        icon: Icon(
                                          _obscurePassword
                                              ? Icons.visibility
                                              : Icons.visibility_off,
                                          size: 18,
                                        ),
                                        onPressed: () {
                                          setState(() {
                                            _obscurePassword =
                                                !_obscurePassword;
                                          });
                                        },
                                      ),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
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
                            child: ElevatedButton.icon(
                              onPressed: _isSavingProxy
                                  ? null
                                  : () => _applyProxy(provider),
                              icon: _isSavingProxy
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.check, size: 18),
                              label: const Text('Apply Proxy Settings'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor:
                                    AppTheme.neonAmber.withValues(alpha: 0.2),
                                foregroundColor: AppTheme.neonAmber,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: BorderSide(
                                    color: AppTheme.neonAmber
                                        .withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // =========================================================
                    // SECTION C: SSL / Private Trackers (Session-level)
                    // =========================================================
                    _buildSectionHeader(
                      icon: Icons.lock_outline,
                      title: 'SSL / Private Trackers (Session-level)',
                      color: AppTheme.neonGreen,
                      textClr: textClr,
                      trailing: settings.isSslActive
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    AppTheme.neonGreen.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color:
                                      AppTheme.neonGreen.withValues(alpha: 0.4),
                                ),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.check_circle,
                                    size: 14,
                                    color: AppTheme.neonGreen,
                                  ),
                                  SizedBox(width: 4),
                                  Text(
                                    'SSL Active',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.neonGreen,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Attach client certificates for SSL/TLS encrypted private trackers and secure swarms.',
                            style: TextStyle(fontSize: 12, color: mutedClr),
                          ),
                          const SizedBox(height: 12),
                          // Certificate Picker
                          _buildFilePickerRow(
                            label: 'Certificate (.pem / .crt)',
                            filePath: _selectedCertPath,
                            icon: Icons.verified_user_outlined,
                            onPick: _pickCertFile,
                            onClear: () =>
                                setState(() => _selectedCertPath = null),
                            textClr: textClr,
                            mutedClr: mutedClr,
                            borderColor: borderColor,
                          ),
                          const SizedBox(height: 10),
                          // Key Picker
                          _buildFilePickerRow(
                            label: 'Private Key (.pem / .key)',
                            filePath: _selectedKeyPath,
                            icon: Icons.key_outlined,
                            onPick: _pickKeyFile,
                            onClear: () =>
                                setState(() => _selectedKeyPath = null),
                            textClr: textClr,
                            mutedClr: mutedClr,
                            borderColor: borderColor,
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _isSavingSsl
                                  ? null
                                  : () => _applySsl(provider),
                              icon: _isSavingSsl
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.security, size: 18),
                              label: const Text('Apply SSL Certificates'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor:
                                    AppTheme.neonGreen.withValues(alpha: 0.2),
                                foregroundColor: AppTheme.neonGreen,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: BorderSide(
                                    color: AppTheme.neonGreen
                                        .withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 30),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required Color color,
    required Color textClr,
    Widget? trailing,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: textClr,
            ),
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _buildFilePickerRow({
    required String label,
    required String? filePath,
    required IconData icon,
    required VoidCallback onPick,
    required VoidCallback onClear,
    required Color textClr,
    required Color mutedClr,
    required Color borderColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppTheme.neonBlue),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 11, color: mutedClr),
                ),
                Text(
                  filePath != null && filePath.isNotEmpty
                      ? filePath.split(RegExp(r'[\\/]')).last
                      : 'None selected',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        filePath != null ? FontWeight.w600 : FontWeight.normal,
                    color: filePath != null
                        ? textClr
                        : mutedClr.withValues(alpha: 0.6),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (filePath != null && filePath.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear, size: 16),
              onPressed: onClear,
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(4),
            ),
          const SizedBox(width: 4),
          OutlinedButton(
            onPressed: onPick,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Browse', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }
}
