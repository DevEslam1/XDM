import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../../core/services/xdm_backend_client.dart';
import '../../../features/browser/services/ad_blocker_service.dart';
import '../../../features/browser/services/adblock_filter_updater.dart';
import '../provider/settings_provider.dart';
import '../widgets/settings_section_header.dart';
import '../widgets/settings_tiles.dart';

class NetworkSettingsPage extends StatefulWidget {
  const NetworkSettingsPage({super.key});

  @override
  State<NetworkSettingsPage> createState() => _NetworkSettingsPageState();
}

class _NetworkSettingsPageState extends State<NetworkSettingsPage>
    with HapticHelper {
  late final TextEditingController _proxyHostController;
  late final TextEditingController _proxyPortController;
  late final TextEditingController _proxyUsernameController;
  late final TextEditingController _proxyPasswordController;
  late final TextEditingController _backendUrlController;
  bool _testingProxy = false;
  // FIX-5: State variable for testing backend health
  bool _testingBackend = false;
  bool _updatingAdblock = false;
  DateTime? _lastAdblockUpdateTime;

  void _loadLastAdblockUpdateTime() async {
    final dt = await AdBlockFilterUpdater().getLastUpdateTime();
    if (mounted) {
      setState(() {
        _lastAdblockUpdateTime = dt;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    _proxyHostController = TextEditingController(text: settings.proxyHost);
    _proxyPortController =
        TextEditingController(text: settings.proxyPort.toString());
    _proxyUsernameController =
        TextEditingController(text: settings.proxyUsername);
    _proxyPasswordController =
        TextEditingController(text: settings.proxyPassword);
    _backendUrlController = TextEditingController(text: settings.backendUrl);
    _loadLastAdblockUpdateTime();
  }

  @override
  void dispose() {
    _proxyHostController.dispose();
    _proxyPortController.dispose();
    _proxyUsernameController.dispose();
    _proxyPasswordController.dispose();
    _backendUrlController.dispose();
    super.dispose();
  }

  void _maybeConfirmBypassSSL(
      BuildContext context, SettingsProvider settings) async {
    if (!settings.pendingBypassSSLConfirmation) return;
    final confirmed = await DmxConfirmDialog.show(
      context,
      title: L10n.of(context, 'bypass_ssl_dialog_title'),
      message: L10n.of(context, 'bypass_ssl_dialog_body'),
      confirmLabel: L10n.of(context, 'bypass_ssl_dialog_confirm'),
      cancelLabel: L10n.of(context, 'cancel_btn'),
      isDestructive: true,
      icon: Icons.shield_outlined,
    );
    if (confirmed == true) {
      settings.confirmBypassSSL();
    } else {
      settings.setBypassSSL(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // FIX-5: Extraction Backend Server Section & Test Button
          SettingsSectionHeader(
            title: isRtl
                ? 'خادم الاستخراج الخادمي (Backend)'
                : 'Extraction Backend Server',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              TextFieldTile(
                accentColor: accent,
                title: isRtl ? 'عنوان الخادم الخلفي' : 'Backend URL',
                subtitle:
                    'e.g. https://xdm-backend-fallback.europe-west1.run.app',
                controller: _backendUrlController,
                onChanged: (val) => settings.setBackendUrl(val),
                onSubmitted: (val) => settings.setBackendUrl(val),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                child: Row(
                  children: [
                    Expanded(
                      child: NeonGlowButton(
                        isFilled: false,
                        color: accent,
                        text: _testingBackend
                            ? (isRtl ? 'جاري الاختبار...' : 'TESTING...')
                            : (isRtl ? 'اختبار اتصال الخادم' : 'TEST BACKEND'),
                        onPressed: _testingBackend
                            ? null
                            : () async {
                                setState(() => _testingBackend = true);
                                bool healthy = false;
                                try {
                                  final res = await XdmBackendClient().health();
                                  healthy = res.isNotEmpty;
                                } catch (_) {
                                  healthy = false;
                                }
                                if (!mounted || !context.mounted) return;
                                setState(() => _testingBackend = false);
                                ThemedSnackbar.show(
                                  context,
                                  message: healthy
                                      ? (isRtl
                                          ? 'الخادم يعمل بنجاح!'
                                          : 'Backend is reachable!')
                                      : (isRtl
                                          ? 'فشل الاتصال بالخادم'
                                          : 'Backend unreachable'),
                                  color: healthy
                                      ? AppTheme.neonGreen
                                      : AppTheme.neonRed,
                                  icon: healthy
                                      ? Icons.check_circle_outline
                                      : Icons.error_outline,
                                  isDarkMode: isDark,
                                );
                              },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsSectionHeader(
            title: isRtl ? 'قيود الشبكة' : 'Connectivity Restrictions',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              SwitchTile(
                accentColor: accent,
                title: L10n.of(context, 'settings_wifi_only'),
                subtitle: L10n.of(context, 'settings_wifi_only_sub'),
                value: settings.wifiOnly,
                onChanged: (val) {
                  settings.setWifiOnly(val);
                  triggerHaptic(settings);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsSectionHeader(
            title: isRtl ? 'إعدادات البروكسي (Proxy)' : 'HTTP / SOCKS Proxy',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              SwitchTile(
                accentColor: accent,
                title: L10n.of(context, 'settings_proxy'),
                subtitle: L10n.of(context, 'settings_proxy_sub'),
                value: settings.enableProxy,
                onChanged: (val) {
                  settings.setEnableProxy(val);
                  triggerHaptic(settings);
                },
              ),
              if (settings.enableProxy) ...[
                TextFieldTile(
                  accentColor: accent,
                  title: isRtl ? 'عنوان المضيف (Host)' : 'Proxy Host',
                  subtitle: '127.0.0.1 or proxy.example.com',
                  controller: _proxyHostController,
                  onChanged: (val) => settings.setProxyHost(val),
                  onSubmitted: (val) => settings.setProxyHost(val),
                ),
                TextFieldTile(
                  accentColor: accent,
                  title: isRtl ? 'المنفذ (Port)' : 'Proxy Port',
                  subtitle: '8080',
                  controller: _proxyPortController,
                  keyboardType: TextInputType.number,
                  onChanged: (val) {
                    final port = int.tryParse(val);
                    if (port != null) settings.setProxyPort(port);
                  },
                  onSubmitted: (val) {
                    final port = int.tryParse(val);
                    if (port != null) settings.setProxyPort(port);
                  },
                ),
                TextFieldTile(
                  accentColor: accent,
                  title: isRtl ? 'اسم المستخدم' : 'Proxy Username',
                  subtitle: 'Optional username',
                  controller: _proxyUsernameController,
                  onChanged: (val) => settings.setProxyUsername(val),
                  onSubmitted: (val) => settings.setProxyUsername(val),
                ),
                TextFieldTile(
                  accentColor: accent,
                  title: isRtl ? 'كلمة المرور' : 'Proxy Password',
                  subtitle: 'Stored in Secure Storage',
                  controller: _proxyPasswordController,
                  obscureText: true,
                  onChanged: (val) => settings.setProxyPassword(val),
                  onSubmitted: (val) => settings.setProxyPassword(val),
                ),
              ],
            ],
          ),
          if (settings.enableProxy)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
              child: NeonGlowButton(
                isFilled: false,
                color: accent,
                text: _testingProxy
                    ? (isRtl ? 'جاري الاختبار...' : 'TESTING PROXY...')
                    : (isRtl
                        ? 'اختبار اتصال البروكسي'
                        : 'TEST PROXY CONNECTION'),
                onPressed: _testingProxy
                    ? null
                    : () async {
                        final isRtl = L10n.isRtl(context);
                        final isDark = settings.isDarkMode;
                        setState(() => _testingProxy = true);
                        final success = await settings.testProxyConnection(
                          settings.proxyHost,
                          settings.proxyPort,
                          settings.proxyUsername,
                          settings.proxyPassword,
                          bypassSSL: settings.bypassSSL,
                        );
                        if (!mounted || !context.mounted) return;
                        setState(() => _testingProxy = false);
                        ThemedSnackbar.show(
                          context,
                          message: success
                              ? (isRtl
                                  ? 'اتصال البروكسي ناجح!'
                                  : 'Proxy connection successful!')
                              : (isRtl
                                  ? 'فشل اتصال البروكسي'
                                  : 'Proxy connection failed'),
                          color:
                              success ? AppTheme.neonGreen : AppTheme.neonRed,
                          icon: success
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          isDarkMode: isDark,
                        );
                      },
              ),
            ),
          const SizedBox(height: 12),
          SettingsSectionHeader(
            title: isRtl ? 'الأمان والخصوصية' : 'Security & Privacy',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              if (settings.developerMode)
                SwitchTile(
                  accentColor:
                      isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                  title: L10n.of(context, 'settings_bypass_ssl'),
                  subtitle: L10n.of(context, 'settings_bypass_ssl_sub'),
                  value: settings.bypassSSL,
                  onChanged: (val) {
                    settings.setBypassSSL(val);
                    triggerHaptic(settings);
                    _maybeConfirmBypassSSL(context, settings);
                  },
                ),
              SwitchTile(
                accentColor: accent,
                title: L10n.of(context, 'settings_https_only'),
                subtitle: L10n.of(context, 'settings_https_only_sub'),
                value: settings.httpsOnly,
                onChanged: (val) {
                  settings.setHttpsOnly(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl
                    ? 'حماية ضد تتبع البصمة الرقمية'
                    : 'Anti-Fingerprinting Protection',
                subtitle: isRtl
                    ? 'إخفاء بصمات الأتمتة navigator.webdriver في المتصفح'
                    : 'Obscure navigator.webdriver & WebView signatures to prevent bot detection',
                value: settings.antiFingerprinting,
                onChanged: (val) {
                  settings.setAntiFingerprinting(val);
                  triggerHaptic(settings);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          // AdBlocker & Host Filters Section
          SettingsSectionHeader(
            title: L10n.of(context, 'settings_adblock_title'),
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              SwitchTile(
                accentColor: accent,
                title: L10n.of(context, 'settings_enable_adblock'),
                subtitle: L10n.of(context, 'settings_enable_adblock_sub'),
                value: AdBlockerService.instance.isEnabled,
                onChanged: (val) async {
                  await AdBlockerService.instance.setEnabled(val);
                  triggerHaptic(settings);
                  if (mounted) setState(() {});
                },
              ),
              if (AdBlockerService.instance.isEnabled) ...[
                ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  title: Text(
                    L10n.of(context, 'settings_adblock_rules'),
                    style: TextStyle(
                      fontFamily: 'Space Grotesk',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? AppTheme.textPrimary
                          : AppTheme.lightTextPrimary,
                    ),
                  ),
                  subtitle: Text(
                    '${AdBlockerService.instance.ruleCount} ${isRtl ? 'قاعدة نشطة محملة' : 'active blocklist rules loaded'}'
                    '${_lastAdblockUpdateTime != null ? '\n${isRtl ? 'آخر تحديث:' : 'Last updated:'} ${_lastAdblockUpdateTime!.toLocal().toString().split('.')[0]}' : ''}',
                    style: TextStyle(
                      fontFamily: 'Space Grotesk',
                      fontSize: 12,
                      color: isDark
                          ? AppTheme.textSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                  trailing: Icon(
                    Icons.security_outlined,
                    color: accent,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: NeonGlowButton(
                    isFilled: false,
                    color: accent,
                    text: _updatingAdblock
                        ? L10n.of(context, 'settings_updating_adblock_hosts')
                        : L10n.of(context, 'settings_update_adblock_hosts'),
                    onPressed: _updatingAdblock
                        ? null
                        : () async {
                            setState(() => _updatingAdblock = true);
                            ThemedSnackbar.show(
                              context,
                              message: L10n.of(
                                  context, 'settings_adblock_updating_msg'),
                              color: accent,
                              isDarkMode: isDark,
                              icon: Icons.sync,
                            );
                            bool updated = false;
                            try {
                              updated = await AdBlockerService.instance
                                  .updateFilters(force: true);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context)
                                    .hideCurrentSnackBar();
                                ThemedSnackbar.show(
                                  context,
                                  message: updated
                                      ? L10n.of(context,
                                          'settings_adblock_success_msg')
                                      : L10n.of(context,
                                          'settings_adblock_success_msg'),
                                  color: AppTheme.neonGreen,
                                  icon: Icons.check_circle_outline,
                                  isDarkMode: isDark,
                                );
                              }
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context)
                                    .hideCurrentSnackBar();
                                ThemedSnackbar.show(
                                  context,
                                  message: L10n.of(
                                      context, 'settings_adblock_failed_msg'),
                                  color: AppTheme.neonRed,
                                  icon: Icons.error_outline,
                                  isDarkMode: isDark,
                                );
                              }
                            } finally {
                              if (mounted) {
                                if (updated) {
                                _loadLastAdblockUpdateTime();
                              }
                              setState(() => _updatingAdblock = false);
                              }
                            }
                          },
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
