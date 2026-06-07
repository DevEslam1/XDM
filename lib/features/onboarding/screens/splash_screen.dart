import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:local_auth/local_auth.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/dmx_app_icon.dart';
import '../../settings/provider/settings_provider.dart';
import 'onboarding_screen.dart';
import '../../../shared/widgets/main_navigation_container.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _logoController;
  final List<String> _bootLogs = [];
  int _logIndex = 0;
  Timer? _logTimer;
  bool _authFailed = false;

  final LocalAuthentication _auth = LocalAuthentication();

  final List<String> _rawLogs = [
    '>> INITIALIZING COCKPIT CORE ENGINE...',
    '>> ALLOCATING MULTITHREADED RANGE BUFFERS...',
    '>> LOADING TRANSFERRED TRANSMISSION LOGS...',
    '>> BINDING AUDIOWAVE CHIME SYSTEM...',
    '>> ESTABLISHING HAPTIC PULSE INTERRUPTS...',
    '>> SYSTEM DIAGNOSTICS: 100% OPERATIONAL.',
    '>> BOOT COMPLETED.',
  ];

  @override
  void initState() {
    super.initState();
    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _navigateToNext();
        }
      });
    } else {
      _printNextLog();
    }
  }

  void _printNextLog() {
    if (_logIndex < _rawLogs.length) {
      _logTimer = Timer(
        Duration(milliseconds: 300 + (_logIndex == 5 ? 400 : 0)),
        () {
          if (mounted) {
            setState(() {
              _bootLogs.add(_rawLogs[_logIndex]);
              _logIndex++;
            });
            final settings = Provider.of<SettingsProvider>(
              context,
              listen: false,
            );
            if (settings.vibration) {
              HapticFeedback.selectionClick();
            }
            _printNextLog();
          }
        },
      );
    } else {
      Timer(const Duration(milliseconds: 600), () {
        if (mounted) {
          _verifyLockAndNavigate();
        }
      });
    }
  }

  Future<void> _verifyLockAndNavigate() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (settings.biometricLock) {
      final isRtl = L10n.isRtl(context);
      try {
        final bool canCheck = await _auth.canCheckBiometrics;
        final bool isSupported = await _auth.isDeviceSupported();
        if (canCheck || isSupported) {
          final bool didAuth = await _auth.authenticate(
            localizedReason: isRtl
                ? 'يرجى تأكيد هويتك لفتح لوحة قيادة XDM'
                : 'Please authenticate to open XDM dashboard',
            biometricOnly: false,
            persistAcrossBackgrounding: true,
          );
          if (didAuth) {
            if (mounted) {
              setState(() {
                _authFailed = false;
              });
            }
            _navigateToNext();
          } else {
            if (mounted) {
              setState(() {
                _authFailed = true;
              });
            }
          }
        } else {
          // Device has no biometric capability at all; the user has
          // nothing to authenticate with, so we let them in.
          _navigateToNext();
        }
      } catch (e) {
        debugPrint('SplashScreen biometric lock error: $e');
        if (e is LocalAuthException) {
          if (e.code == LocalAuthExceptionCode.noCredentialsSet ||
              e.code == LocalAuthExceptionCode.noBiometricsEnrolled ||
              e.code == LocalAuthExceptionCode.noBiometricHardware) {
            debugPrint('Device has no biometric or passcode configured. Letting the user in.');
            _navigateToNext();
            return;
          }
        }
        if (e is PlatformException) {
          final code = e.code.toLowerCase();
          if (code == 'notavailable' || code == 'notenrolled' || code == 'passcodenotset') {
            debugPrint('Device has no biometric or passcode configured. Letting the user in.');
            _navigateToNext();
            return;
          }
        }
        if (mounted) {
          setState(() {
            _authFailed = true;
          });
        }
      }
    } else {
      _navigateToNext();
    }
  }

  void _navigateToNext() {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => settings.showOnboarding
            ? const OnboardingScreen()
            : const MainNavigationContainer(),
      ),
    );
  }

  @override
  void dispose() {
    _logoController.dispose();
    _logTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final isRtl = L10n.isRtl(context);

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Directionality(
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(28.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Spacer(),
                  // Spinning Glowing X Logo
                  RotationTransition(
                    turns: _logoController,
                    child: const DmxAppIcon(size: 72, showGlow: true),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'XDM // TRANSMISSION GATE',
                    style: TextStyle(
                      color: textClr,
                      fontFamily: 'Space Grotesk',
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.0,
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(),
                  // Telemetry CLI logs box or Retry Auth Button
                  _authFailed
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              isRtl
                                  ? 'فشل التحقق من الهوية'
                                  : 'IDENTITY VERIFICATION FAILED',
                              style: TextStyle(
                                color: isDark
                                    ? AppTheme.neonRed
                                    : AppTheme.lightNeonRed,
                                fontFamily: 'Space Grotesk',
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                letterSpacing: 1.0,
                              ),
                            ),
                            const SizedBox(height: 16),
                            NeonGlowButton(
                              isFilled: true,
                              color: isDark
                                  ? AppTheme.neonRed
                                  : AppTheme.lightNeonRed,
                              onPressed: _verifyLockAndNavigate,
                              text: isRtl
                                  ? 'إعادة التحقق'
                                  : 'RETRY VERIFICATION',
                            ),
                          ],
                        )
                      : Container(
                          width: double.infinity,
                          height: 180,
                          padding: const EdgeInsets.all(16.0),
                          decoration: BoxDecoration(
                            color: (isDark ? Colors.black : Colors.white)
                                .withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isDark
                                  ? AppTheme.glassBorder
                                  : AppTheme.lightGlassBorder,
                              width: 0.8,
                            ),
                          ),
                          child: ListView.builder(
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _bootLogs.length,
                            itemBuilder: (context, index) {
                              final isLast = index == _bootLogs.length - 1;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 6.0),
                                child: Text(
                                  _bootLogs[index],
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: isLast
                                        ? (isDark
                                              ? AppTheme.neonGreen
                                              : AppTheme.lightNeonGreen)
                                        : (isDark
                                              ? AppTheme.textSecondary
                                              : AppTheme.lightTextSecondary),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                  const SizedBox(height: 12),
                  Text(
                    'FIRMWARE REVISION v2.0.26',
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textMuted
                          : AppTheme.lightTextMuted,
                      fontSize: 8,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
