import 'package:flutter/material.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ShareUrlHandler.handle(context, widget.url, isShareLaunch: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black54,
      body: Container(
        color: Colors.transparent,
        width: double.infinity,
        height: double.infinity,
      ),
    );
  }
}
