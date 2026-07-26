import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../core/services/share_url_handler.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'geometric_grid_background.dart';

class ShareLaunchScreen extends StatefulWidget {
  final String url;
  const ShareLaunchScreen({super.key, required this.url});

  @override
  State<ShareLaunchScreen> createState() => _ShareLaunchScreenState();
}

class _ShareLaunchScreenState extends State<ShareLaunchScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await ShareUrlHandler.handle(context, widget.url, isShareLaunch: true);
      } catch (e) {
        debugPrint('[ShareLaunchScreen] Error handling share URL: $e');
      } finally {
        if (mounted) {
          await Future.delayed(const Duration(milliseconds: 300));
          SystemNavigator.pop();
        }
      }
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.select((SettingsProvider s) => s.isDarkMode);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: _pulse,
                builder: (context, _) {
                  return Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: accent.withValues(
                        alpha: 0.08 + _pulse.value * 0.06,
                      ),
                      border: Border.all(
                        color: accent.withValues(
                          alpha: 0.35 + _pulse.value * 0.25,
                        ),
                        width: 1.2,
                      ),
                    ),
                    child: Icon(Icons.share_rounded, color: accent, size: 28),
                  );
                },
              ),
              const SizedBox(height: 20),
              Text(
                'ROUTING SIGNAL…',
                style: AppTheme.microLabel(
                  isDark: isDark,
                  color: accent,
                  size: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
