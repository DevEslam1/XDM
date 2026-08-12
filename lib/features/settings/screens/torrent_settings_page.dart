import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/haptic_helper.dart';
import '../provider/settings_provider.dart';
import '../widgets/settings_section_header.dart';
import '../widgets/settings_tiles.dart';

class TorrentSettingsPage extends StatelessWidget with HapticHelper {
  const TorrentSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;

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
          SettingsSectionHeader(
            title: isRtl ? 'جلسة التورنت والبروتوكولات' : 'Session & Protocols',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              SwitchTile(
                accentColor: accent,
                title:
                    isRtl ? 'تمكين DHT' : 'Enable DHT (Distributed Hash Table)',
                subtitle: isRtl
                    ? 'البحث عن الأقران بدون خادم تتبع مركزي'
                    : 'Peer discovery via decentralized DHT network',
                value: settings.enableDht,
                onChanged: (val) {
                  settings.setEnableDht(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'تمكين UPnP' : 'Enable UPnP Port Mapping',
                subtitle: isRtl
                    ? 'فتح المنافذ تلقائياً في الراوتر'
                    : 'Automatic router port forwarding via UPnP',
                value: settings.enableUpnp,
                onChanged: (val) {
                  settings.setEnableUpnp(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'تمكين NAT-PMP' : 'Enable NAT-PMP',
                subtitle: isRtl
                    ? 'توجيه المنافذ لأجهزة الراوتر المدعومة'
                    : 'NAT Port Mapping Protocol for Apple/supported routers',
                value: settings.enableNatPmp,
                onChanged: (val) {
                  settings.setEnableNatPmp(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title:
                    isRtl ? 'تمكين LPD' : 'Enable LPD (Local Peer Discovery)',
                subtitle: isRtl
                    ? 'اكتشاف الأقران المتاحين على الشبكة المحلية'
                    : 'Discover peers on local area network',
                value: settings.enableLpd,
                onChanged: (val) {
                  settings.setEnableLpd(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'تمكين PEX' : 'Enable PEX (Peer Exchange)',
                subtitle: isRtl
                    ? 'تبادل الأقران مباشرة مع المتصلين'
                    : 'Exchange peer list directly with connected swarm peers',
                value: settings.enablePex,
                onChanged: (val) {
                  settings.setEnablePex(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'إجبار التشفير' : 'Force Encryption',
                subtitle: isRtl
                    ? 'تشفير الاتصالات لحماية الخصوصية وتجاوز حجب ISP'
                    : 'Require protocol encryption to prevent ISP throttling',
                value: settings.forceEncrypt,
                onChanged: (val) {
                  settings.setForceEncrypt(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'التحميل المتسلسل' : 'Sequential Download',
                subtitle: isRtl
                    ? 'تحميل القطع بترتيب متسلسل لمعاينة الفيديو أثناء التحميل'
                    : 'Download pieces linearly start-to-end for video streaming',
                value: settings.sequentialDownload,
                onChanged: (val) {
                  settings.setSequentialDownload(val);
                  triggerHaptic(settings);
                },
              ),
              SliderTile(
                accentColor: accent,
                title: isRtl ? 'أقصى عدد للاتصالات' : 'Connection Limit',
                subtitle: '${settings.torrentConnectionsLimit} peers',
                value: settings.torrentConnectionsLimit.toDouble(),
                min: 10,
                max: 1000,
                divisions: 99,
                onChanged: (val) {
                  settings.setTorrentConnectionsLimit(val.round());
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsSectionHeader(
            title: isRtl ? 'إدارة الدور والرفع (Seeding)' : 'Queue & Seeding',
            accentColor: accent,
            isDark: isDark,
          ),
          SettingsSectionGroup(
            accentColor: accent,
            children: [
              SwitchTile(
                accentColor: accent,
                title: isRtl
                    ? 'تفعيل رفع التورنت (Seeding)'
                    : 'Global Torrent Seeding',
                subtitle: isRtl
                    ? 'مشاركة القطع المحملة مع شبكة التورنت'
                    : 'Upload completed pieces to support swarm health',
                value: settings.globalTorrentSeeding,
                onChanged: (val) {
                  settings.setGlobalTorrentSeeding(val);
                  triggerHaptic(settings);
                },
              ),
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'تقييد سرعة الرفع' : 'Limit Seeding Speed',
                subtitle: isRtl
                    ? 'تحديد الحد الأقصى لسرعة رفع التورنت'
                    : 'Cap total upload bandwidth for seeding torrents',
                value: settings.globalTorrentSeedingLimited,
                onChanged: (val) {
                  settings.setGlobalTorrentSeedingLimited(val);
                  triggerHaptic(settings);
                },
              ),
              if (settings.globalTorrentSeedingLimited)
                SliderTile(
                  accentColor: accent,
                  title: isRtl
                      ? 'أقصى سرعة رفع (KB/s)'
                      : 'Max Upload Speed (KB/s)',
                  subtitle: '${settings.globalTorrentSeedingLimitKbps} KB/s',
                  value: settings.globalTorrentSeedingLimitKbps.toDouble(),
                  min: 100,
                  max: 10000,
                  divisions: 99,
                  onChanged: (val) {
                    settings.setGlobalTorrentSeedingLimitKbps(val.round());
                  },
                ),
              SwitchTile(
                accentColor: accent,
                title: isRtl ? 'جدولة دور التورنت' : 'Queue Torrents',
                subtitle: isRtl
                    ? 'الالتزام بالحدود القصوى للتحميل والرفع المتزامن'
                    : 'Enforce active torrent & seed concurrency limits',
                value: settings.queueTorrents,
                onChanged: (val) {
                  settings.setQueueTorrents(val);
                  triggerHaptic(settings);
                },
              ),
              DropdownTile<int>(
                accentColor: accent,
                title: isRtl ? 'أقصى تورنت نشط' : 'Max Active Torrents',
                subtitle: '${settings.maxActiveTorrents} active',
                value: settings.maxActiveTorrents,
                items: const [1, 2, 3, 5, 10, 20, 50],
                onChanged: (val) {
                  if (val != null) {
                    settings.setMaxActiveTorrents(val);
                    triggerHaptic(settings);
                  }
                },
              ),
              DropdownTile<int>(
                accentColor: accent,
                title:
                    isRtl ? 'أقصى تحميلات تورنت نشطة' : 'Max Active Downloads',
                subtitle: '${settings.maxActiveDownloads} downloading',
                value: settings.maxActiveDownloads,
                items: const [1, 2, 3, 5, 10, 20],
                onChanged: (val) {
                  if (val != null) {
                    settings.setMaxActiveDownloads(val);
                    triggerHaptic(settings);
                  }
                },
              ),
              DropdownTile<int>(
                accentColor: accent,
                title: isRtl ? 'أقصى عملية رفع نشطة' : 'Max Active Seeds',
                subtitle: '${settings.maxActiveSeeds} seeding',
                value: settings.maxActiveSeeds,
                items: const [0, 1, 2, 3, 5, 10, 20],
                onChanged: (val) {
                  if (val != null) {
                    settings.setMaxActiveSeeds(val);
                    triggerHaptic(settings);
                  }
                },
              ),
              SliderTile(
                accentColor: accent,
                title: isRtl
                    ? 'حد نسبة المشاركة (Share Ratio)'
                    : 'Share Ratio Limit',
                subtitle:
                    'Ratio: ${settings.shareRatioLimit.toStringAsFixed(1)}x',
                value: settings.shareRatioLimit,
                min: 0.5,
                max: 10.0,
                divisions: 19,
                onChanged: (val) {
                  settings.setShareRatioLimit(val);
                },
              ),
              DropdownTile<int>(
                accentColor: accent,
                title: isRtl ? 'أقصى زمن للرفع' : 'Max Seeding Time',
                subtitle: settings.maxSeedingTimeMinutes == 0
                    ? (isRtl ? 'غير محدود' : 'Unlimited (0 mins)')
                    : '${settings.maxSeedingTimeMinutes} minutes',
                value: settings.maxSeedingTimeMinutes,
                items: const [0, 15, 30, 60, 120, 240, 1440],
                itemLabels: const {
                  0: 'UNLIMITED',
                  15: '15 MINS',
                  30: '30 MINS',
                  60: '1 HOUR',
                  120: '2 HOURS',
                  240: '4 HOURS',
                  1440: '24 HOURS',
                },
                onChanged: (val) {
                  if (val != null) {
                    settings.setMaxSeedingTime(val);
                    triggerHaptic(settings);
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
