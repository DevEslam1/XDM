import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/main_navigation_container.dart';
import '../../settings/provider/settings_provider.dart';

class PermissionRequestScreen extends StatefulWidget {
  const PermissionRequestScreen({super.key});

  @override
  State<PermissionRequestScreen> createState() => _PermissionRequestScreenState();
}

class _PermissionRequestScreenState extends State<PermissionRequestScreen>
    with WidgetsBindingObserver {
  final PermissionService _permissionService = PermissionService();
  bool _storageRequested = false;
  bool _storageGranted = false;
  bool _notificationsRequested = false;
  bool _notificationsGranted = false;
  bool _batteryRequested = false;
  bool _batteryGranted = false;
  bool _isNavigating = false;
  bool _pendingBatteryCheck = false;
  bool _batteryOpening = false;

  @override
  void initState() {
    super.initState();
    // Non-Android platforms don't need these permissions; auto-mark as granted.
    if (kIsWeb || !Platform.isAndroid) {
      _storageRequested = true;
      _storageGranted = true;
      _notificationsRequested = true;
      _notificationsGranted = true;
      _batteryRequested = true;
      _batteryGranted = true;
      return;
    }
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _pendingBatteryCheck) {
      _pendingBatteryCheck = false;
      PermissionService().requestBatteryOptimizationExemption().then((granted) {
        if (mounted) setState(() => _batteryGranted = granted);
      });
    }
  }

  static bool _isAndroidPlatform() {
    return !kIsWeb && Platform.isAndroid;
  }

  Future<void> _requestStorage() async {
    if (_storageRequested || !_isAndroidPlatform()) return;
    setState(() => _storageRequested = true);
    try {
      final granted = await _permissionService.ensureStorageAccess();
      if (mounted) setState(() => _storageGranted = granted);
    } catch (_) {
      if (mounted) setState(() => _storageGranted = false);
    }
  }

  Future<void> _requestNotifications() async {
    if (_notificationsRequested || !_isAndroidPlatform()) return;
    setState(() => _notificationsRequested = true);
    try {
      final granted = await NotificationService().requestNotificationPermission();
      if (mounted) setState(() => _notificationsGranted = granted);
    } catch (_) {
      if (mounted) setState(() => _notificationsGranted = false);
    }
  }

  Future<void> _requestBattery() async {
    if (_batteryRequested || !_isAndroidPlatform()) return;
    setState(() {
      _batteryRequested = true;
      _batteryOpening = true;
    });
    // Opens system battery-optimization settings page — the user must toggle
    // it manually. Detect the return via WidgetsBindingObserver below.
    final granted = await _permissionService.requestBatteryOptimizationExemption();
    if (granted) {
      if (mounted) {
        setState(() {
          _batteryGranted = true;
          _batteryOpening = false;
        });
      }
    } else {
      // User was sent to system settings; re-check when they come back.
      if (mounted) {
        setState(() => _batteryOpening = false);
      }
      _pendingBatteryCheck = true;
    }
  }

  void _continueToApp() {
    if (_isNavigating) return;
    _isNavigating = true;
    HapticFeedback.mediumImpact();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => const MainNavigationContainer(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Directionality(
          textDirection: L10n.isRtl(context) ? TextDirection.rtl : TextDirection.ltr,
          child: SafeArea(
            child: Column(
              children: [
                const Spacer(flex: 1),
                // Title
                Text(
                  L10n.of(context, 'permission_title'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                    fontFamily: 'Space Grotesk',
                    fontWeight: FontWeight.bold,
                    fontSize: 26,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  L10n.of(context, 'permission_subtitle'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: secClr,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 40),

                // Permission cards
                _PermissionCard(
                  icon: Icons.folder_outlined,
                  title: L10n.of(context, 'permission_storage_title'),
                  description: L10n.of(context, 'permission_storage_desc'),
                  isLoading: _storageRequested && !_storageGranted,
                  isGranted: _storageGranted,
                  isRequested: _storageRequested,
                  onRequest: _requestStorage,
                  accentColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                  isDark: isDark,
                ),
                const SizedBox(height: 12),
                _PermissionCard(
                  icon: Icons.notifications_outlined,
                  title: L10n.of(context, 'permission_notifications_title'),
                  description: L10n.of(context, 'permission_notifications_desc'),
                  isLoading: _notificationsRequested && !_notificationsGranted,
                  isGranted: _notificationsGranted,
                  isRequested: _notificationsRequested,
                  onRequest: _requestNotifications,
                  accentColor: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                  isDark: isDark,
                ),
                const SizedBox(height: 12),
                _PermissionCard(
                  icon: Icons.battery_std_outlined,
                  title: L10n.of(context, 'permission_battery_title'),
                  description: _batteryOpening
                      ? L10n.of(context, 'permission_battery_opening')
                      : L10n.of(context, 'permission_battery_desc'),
                  isLoading: _batteryOpening,
                  isGranted: _batteryGranted,
                  isRequested: _batteryRequested,
                  onRequest: _requestBattery,
                  accentColor: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
                  isDark: isDark,
                ),

                const Spacer(flex: 1),

                // Continue button
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _continueToApp,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        L10n.of(context, 'permission_continue'),
                        style: const TextStyle(
                          fontFamily: 'Space Grotesk',
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool isLoading;
  final bool isGranted;
  final bool isRequested;
  final VoidCallback onRequest;
  final Color accentColor;
  final bool isDark;

  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.isLoading,
    required this.isGranted,
    required this.isRequested,
    required this.onRequest,
    required this.accentColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final bgClr = isDark ? AppTheme.cardBg : AppTheme.lightCardBg;
    final txtClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: bgClr,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isGranted
              ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
              : (isDark ? AppTheme.border : AppTheme.lightBorder),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accentColor, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: txtClr,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(
                    color: secClr,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isGranted)
            Icon(Icons.check_circle, color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen, size: 24)
          else if (isLoading)
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: accentColor,
              ),
            )
          else
            SizedBox(
              height: 34,
              child: ElevatedButton(
                onPressed: onRequest,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  elevation: 0,
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('Allow'),
              ),
            ),
        ],
      ),
    );
  }
}
