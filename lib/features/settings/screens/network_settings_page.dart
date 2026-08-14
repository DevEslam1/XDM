import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/haptic_helper.dart';
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
  late final TextEditingController _backendUrlController;
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
    _backendUrlController = TextEditingController(text: settings.backendUrl);
    _loadLastAdblockUpdateTime();
  }

  @override
  void dispose() {
    _backendUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonCyan : AppTheme.lightNeonCyan;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(
        left: 12.0,
        right: 12.0,
        top: 16.0,
        bottom: 84.0,
      ),
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
            title: isRtl ? 'الأمان والخصوصية' : 'Security & Privacy',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
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
                                          'settings_adblock_failed_msg'),
                                  color: updated
                                      ? AppTheme.neonGreen
                                      : AppTheme.neonRed,
                                  icon: updated
                                      ? Icons.check_circle_outline
                                      : Icons.error_outline,
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
                                _loadLastAdblockUpdateTime();
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
