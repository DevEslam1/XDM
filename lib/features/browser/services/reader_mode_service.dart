import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';

class ReaderArticle {
  final String title;
  final String content;
  final String url;
  final String domain;
  final String? author;
  final String? publishedDate;
  final String? textContent;
  final List<Map<String, String>> images;
  final int wordCount;
  final int readingTime;

  const ReaderArticle({
    required this.title,
    required this.content,
    required this.url,
    required this.domain,
    this.author,
    this.publishedDate,
    this.textContent,
    this.images = const [],
    this.wordCount = 0,
    this.readingTime = 0,
  });
}

class ReaderModeService {
  static const _extractJs = '''
(function() {
  // FIX(B13): Avoid document.cloneNode(true) which can trigger heavy layout /
  // style recalcs and copies scripts. Read only the body HTML, cap its size,
  // and parse it into a detached div instead.
  var bodyHtml = document.body ? document.body.innerHTML : '';
  if (bodyHtml.length > 500000) {
    bodyHtml = bodyHtml.substring(0, 500000);
  }
  var doc = document.createElement('div');
  doc.innerHTML = bodyHtml;

  var removeSelectors = [
    'script', 'style', 'nav', 'footer', 'header',
    '.sidebar', '.nav', '.footer', '.header', '.ad',
    '.ads', '.advertisement', '[role="navigation"]',
    '[role="banner"]', '.social-share', '.comments',
    '.related-articles', '.newsletter', 'iframe'
  ];
  
  removeSelectors.forEach(function(sel) {
    doc.querySelectorAll(sel).forEach(function(el) { el.remove(); });
  });
  
  var candidates = [
    doc.querySelector('article'),
    doc.querySelector('[role="main"]'),
    doc.querySelector('main'),
    doc.querySelector('.post-content'),
    doc.querySelector('.article-body'),
    doc.querySelector('.entry-content'),
    doc.querySelector('#content'),
    doc
  ];
  
  var content = null;
  for (var i = 0; i < candidates.length; i++) {
    var candidate = candidates[i];
    if (candidate && candidate.textContent && candidate.textContent.trim().length > 100) {
      content = candidate;
      break;
    }
  }
  
  if (!content) return JSON.stringify(null);
  
  var title = doc.querySelector('h1') ? doc.querySelector('h1').textContent : null;
  if (!title || !title.trim()) title = document.title;
  
  var authorEl = doc.querySelector('[rel="author"]');
  var author = authorEl ? authorEl.textContent : null;
  if (!author) {
    var authorMeta = document.querySelector('meta[name="author"]');
    author = authorMeta ? authorMeta.getAttribute('content') : null;
  }
  
  var timeEl = doc.querySelector('time');
  var publishedDate = timeEl ? timeEl.getAttribute('datetime') : null;
  if (!publishedDate) {
    var pubMeta = document.querySelector('meta[property="article:published_time"]');
    publishedDate = pubMeta ? pubMeta.getAttribute('content') : null;
  }
  
  var images = Array.prototype.slice.call(content.querySelectorAll('img'))
    .map(function(img) { return { src: img.src, alt: img.alt || '' }; })
    .filter(function(img) { return img.src && img.src.indexOf('data:') !== 0; });
  
  var fullText = content.textContent ? content.textContent : '';
  var textContent = fullText.trim().substring(0, 5000);
  var words = fullText.split(/\\s+/).filter(Boolean).length;
  var readingTime = Math.ceil(words / 200);

  return JSON.stringify({
    title: title ? title.trim() : 'Untitled',
    author: author ? author.trim() : null,
    publishedDate: publishedDate || null,
    content: content.innerHTML,
    textContent: textContent,
    images: images,
    wordCount: words,
    readingTime: readingTime,
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
          .timeout(const Duration(seconds: 10))
          .catchError((_) => null);
      if (result == null || result == 'null') return null;
      final data = jsonDecode(result.toString()) as Map<String, dynamic>;
      final rawImages = data['images'] as List<dynamic>? ?? [];
      final parsedImages = rawImages.map((e) {
        final m = e as Map<String, dynamic>;
        return {
          'src': m['src']?.toString() ?? '',
          'alt': m['alt']?.toString() ?? '',
        };
      }).toList();

      return ReaderArticle(
        title: data['title'] as String? ?? 'Untitled',
        content: data['content'] as String? ?? '',
        url: data['url'] as String? ?? '',
        domain: data['domain'] as String? ?? '',
        author: data['author'] as String?,
        publishedDate: data['publishedDate'] as String?,
        textContent: data['textContent'] as String?,
        images: parsedImages,
        wordCount: data['wordCount'] as int? ?? 0,
        readingTime: data['readingTime'] as int? ?? 0,
      );
    } catch (e, st) {
      Logger('reader_mode_service')
          .warning('[reader_mode_service] operation failed', e, st);
      return null;
    }
  }

  static String _escapeHtml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  /// Sanitizes page innerHTML before it is embedded into the reader view.
  /// Removes executable markup (scripts, iframes, object/embed, forms) and
  /// strips event-handler/style attributes and javascript:/data: URLs so page
  /// content cannot execute in reader context.
  static String _sanitizeContent(String htmlText) {
    final stripped = htmlText
        .replaceAll(
            RegExp(
                r'<\s*(script|iframe|object|embed|style|form|link|applet|base|meta)\b[^>]*>.*?<\s*/\s*\1\s*>',
                caseSensitive: false,
                dotAll: true),
            '')
        .replaceAll(
            RegExp(
                r'<\s*(script|iframe|object|embed|style|form|link|applet|base|meta)\b[^>]*/?>',
                caseSensitive: false),
            '')
        .replaceAll(
            RegExp(r'''\son\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''',
                caseSensitive: false),
            '')
        .replaceAll(
            RegExp(r'''\sstyle\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''',
                caseSensitive: false),
            '')
        .replaceAll(
            RegExp(r'<\s*a\s+[^>]*href\s*=\s*"?\s*(javascript|data)\s*:',
                caseSensitive: false, dotAll: true),
            '<a>')
        .replaceAll(
            RegExp(r'href\s*=\s*"?\s*javascript\s*:[^" >]*', caseSensitive: false),
            'href="#"')
        .replaceAll(
            RegExp(r'src\s*=\s*"?\s*javascript\s*:[^" >]*', caseSensitive: false),
            'src=""')
        .replaceAll(
            RegExp(r'<\s*img\b[^>]*\bonerror\b[^>]*>', caseSensitive: false),
            '');
    return stripped;
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
    <h1>${_escapeHtml(article.title)}</h1>
    <small>${_escapeHtml(article.domain)}</small>
  </div>
  ${_sanitizeContent(article.content)}
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
