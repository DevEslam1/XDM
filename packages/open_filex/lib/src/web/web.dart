import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart';

/// Open your file with [uri] on the web
Future<bool> open(String uri) async {
  try {
    final anchor = document.createElement('a') as HTMLAnchorElement;
    anchor.href = uri;
    anchor.target = '_blank';
    anchor.download = uri;
    document.body?.appendChild(anchor);
    anchor.click();
    anchor.remove();
    return true;
  } catch (e) {
    return false;
  }
}
