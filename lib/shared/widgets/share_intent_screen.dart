import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/services/share_url_handler.dart';

class ShareLaunchScreen extends StatefulWidget {
  final String url;
  const ShareLaunchScreen({super.key, required this.url});

  @override
  State<ShareLaunchScreen> createState() => _ShareLaunchScreenState();
}

class _ShareLaunchScreenState extends State<ShareLaunchScreen> {
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();

    _timeoutTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) {
        debugPrint(
          '[ShareLaunchScreen] Share screen timed out after 10 seconds, dismissing automatically.',
        );
        SystemNavigator.pop();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await ShareUrlHandler.handle(context, widget.url, isShareLaunch: true);
      } catch (e) {
        debugPrint('[ShareLaunchScreen] Error handling share URL: $e');
      } finally {
        _timeoutTimer?.cancel();
        if (mounted) {
          await Future.delayed(const Duration(milliseconds: 200));
          SystemNavigator.pop();
        }
      }
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.transparent,
      body: SizedBox.shrink(),
    );
  }
}
