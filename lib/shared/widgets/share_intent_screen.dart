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
  @override
  void initState() {
    super.initState();
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
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.transparent,
      body: SizedBox.shrink(),
    );
  }
}
