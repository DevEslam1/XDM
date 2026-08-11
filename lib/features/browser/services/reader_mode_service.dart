import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
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

  static Future<ReaderArticle?> extract(
    InAppWebViewController controller,
  ) async {
    try {
      final result = await controller
          .evaluateJavascript(source: _extractJs)
          .catchError((_) => null);
      if (result == null) return null;
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

  static String buildReaderHtml(
    ReaderArticle article, {
    required double fontSize,
    required String theme,
    required String fontFamily,
  }) {
    String bg = '#ffffff';
    String fg = '#1a1a1a';
    if (theme == 'dark') {
      bg = '#1a1a2e';
      fg = '#e0e0e0';
    } else if (theme == 'sepia') {
      bg = '#f4ecd8';
      fg = '#5b4636';
    }

    final font =
        fontFamily == 'serif' ? "'Georgia', serif" : "'Inter', sans-serif";

    return '''
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body { 
      background: $bg; 
      color: $fg; 
      font-family: $font; 
      font-size: ${fontSize}px; 
      line-height: 1.8; 
      padding: 20px; 
      max-width: 700px; 
      margin: 0 auto; 
    }
    img { max-width: 100%; height: auto; border-radius: 8px; }
    a { color: #3B82F6; }
    h1, h2, h3 { font-family: 'Space Grotesk', sans-serif; }
    p { margin-bottom: 1.2em; }
    .xdm-reader-header { border-bottom: 1px solid ${theme == 'dark' ? '#333' : '#eee'}; padding-bottom: 12px; margin-bottom: 20px; }
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
    InAppWebViewController controller,
    void Function(String htmlUrl) onLoadReaderUrl, {
    required double fontSize,
    required String theme,
    required String fontFamily,
  }) async {
    final article = await extract(controller);
    if (article == null || article.content.isEmpty) return false;
    return rebuildReaderHtml(
      article,
      onLoadReaderUrl,
      fontSize: fontSize,
      theme: theme,
      fontFamily: fontFamily,
    );
  }

  /// Rebuilds the reader view for an already-extracted [article] using new
  /// appearance settings, without re-extracting from the live page. Used by
  /// the reader-mode controls toolbar (font size, theme, font family).
  static Future<bool> rebuildReaderHtml(
    ReaderArticle article,
    void Function(String htmlUrl) onLoadReaderUrl, {
    required double fontSize,
    required String theme,
    required String fontFamily,
  }) async {
    final htmlContent = buildReaderHtml(
      article,
      fontSize: fontSize,
      theme: theme,
      fontFamily: fontFamily,
    );
    final dataUri = Uri.dataFromString(
      htmlContent,
      mimeType: 'text/html',
      encoding: Encoding.getByName('utf-8'),
    ).toString();
    onLoadReaderUrl(dataUri);
    return true;
  }
}
