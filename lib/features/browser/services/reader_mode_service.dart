import 'dart:convert';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:logging/logging.dart';

class ReaderArticle {
  final String title;
  final String content;
  final String url;
  final String domain;
  const ReaderArticle({
    required this.title,
    required this.content,
    required this.url,
    required this.domain,
  });
}

class ReaderModeService {
  static const _extractJs = '''
(function() {
  const selectors = ['nav', 'footer', 'header', 'aside', '.sidebar', '.nav', '.footer',
    '.header', '.ad', '.ads', '.advertisement', '[role="navigation"]', '[role="banner"]'];
  selectors.forEach(sel => {
    document.querySelectorAll(sel).forEach(el => el.remove());
  });

  const article = document.querySelector('article') ||
                  document.querySelector('[role="main"]') ||
                  document.querySelector('main') ||
                  document.querySelector('.post-content') ||
                  document.querySelector('.article-body') ||
                  document.body;

  const title = document.querySelector('h1')?.textContent || document.title;
  const content = article ? article.innerHTML : '';

  return JSON.stringify({
    title: title.trim(),
    content: content,
    url: window.location.href,
    domain: window.location.hostname
  });
})();
''';

  static const _readerCss = '''
    body { font-family: 'Georgia', serif; line-height: 1.8; padding: 20px; max-width: 700px; margin: 0 auto; }
    img { max-width: 100%; height: auto; border-radius: 8px; }
    a { color: #3B82F6; }
    h1, h2, h3 { font-family: 'Space Grotesk', sans-serif; }
    p { margin-bottom: 1.2em; }
    .xdm-reader-header { border-bottom: 1px solid #333; padding-bottom: 12px; margin-bottom: 20px; }
  ''';

  static Future<ReaderArticle?> extract(
    PlatformWebViewController controller,
  ) async {
    try {
      final result = await controller.runJavaScriptReturningResult(_extractJs);
      final data = jsonDecode(result.toString()) as Map<String, dynamic>;
      return ReaderArticle(
        title: data['title'] as String? ?? 'Untitled',
        content: data['content'] as String? ?? '',
        url: data['url'] as String? ?? '',
        domain: data['domain'] as String? ?? '',
      );
    } catch (e, st) {
      Logger('reader_mode_service')
          .warning('[reader_mode_service] operation failed', e, st);
      return null;
    }
  }

  static String buildReaderHtml(ReaderArticle article, {bool isDark = true}) {
    final bg = isDark ? '#1a1a2e' : '#ffffff';
    final fg = isDark ? '#e0e0e0' : '#1a1a1a';
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body { background: $bg; color: $fg; }
    $_readerCss
  </style>
</head>
<body>
  <div class="xdm-reader-header">
    <h1>${article.title}</h1>
    <small>${article.domain}</small>
  </div>
  ${article.content}
</body>
</html>
''';
  }

  /// Extracts article content and displays it in a clean modal view.
  static Future<bool> activateReaderMode(
    PlatformWebViewController controller,
    void Function(String htmlUrl) onLoadReaderUrl,
  ) async {
    final article = await extract(controller);
    if (article == null || article.content.isEmpty) return false;
    final htmlContent = buildReaderHtml(article);
    final dataUri = Uri.dataFromString(
      htmlContent,
      mimeType: 'text/html',
      encoding: Encoding.getByName('utf-8'),
    ).toString();
    onLoadReaderUrl(dataUri);
    return true;
  }
}
