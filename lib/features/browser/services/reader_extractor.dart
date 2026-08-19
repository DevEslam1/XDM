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

  ReaderArticle copyWith({
    String? title,
    String? content,
    String? url,
    String? domain,
    String? author,
    String? publishedDate,
    String? textContent,
    List<Map<String, String>>? images,
    int? wordCount,
    int? readingTime,
  }) {
    return ReaderArticle(
      title: title ?? this.title,
      content: content ?? this.content,
      url: url ?? this.url,
      domain: domain ?? this.domain,
      author: author ?? this.author,
      publishedDate: publishedDate ?? this.publishedDate,
      textContent: textContent ?? this.textContent,
      images: images ?? this.images,
      wordCount: wordCount ?? this.wordCount,
      readingTime: readingTime ?? this.readingTime,
    );
  }
}

/// Extractor service responsible for JavaScript injection and raw DOM parsing
/// to construct a [ReaderArticle].
class ReaderExtractor {
  static final _log = Logger('reader_extractor');

  static const String extractJs = '''
(function() {
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
          .evaluateJavascript(source: extractJs)
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
      _log.warning('[ReaderExtractor] Extraction failed', e, st);
      return null;
    }
  }
}
