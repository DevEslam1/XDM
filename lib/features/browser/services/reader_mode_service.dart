import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'html_sanitizer.dart';
import 'reader_extractor.dart';
import 'reader_html_builder.dart';

export 'html_sanitizer.dart';
export 'reader_extractor.dart' show ReaderArticle;
export 'reader_html_builder.dart';

class ReaderModeService {
  /// Extracts article content using the [ReaderExtractor].
  static Future<ReaderArticle?> extract(
    InAppWebViewController controller,
  ) async {
    return ReaderExtractor.extract(controller);
  }

  /// Sanitizes raw HTML using the [HtmlSanitizer].
  static String sanitizeContent(String htmlText) {
    return HtmlSanitizer.sanitize(htmlText);
  }

  /// Builds complete reader HTML document.
  static String buildReaderHtml(
    ReaderArticle article, {
    required double fontSize,
    required String theme,
    required String fontFamily,
    String? sanitizedContent,
  }) {
    return ReaderHtmlBuilder.build(
      article: article,
      fontSize: fontSize,
      theme: theme,
      fontFamily: fontFamily,
      sanitizedContent: sanitizedContent,
    );
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
  /// appearance settings, offloading HTML sanitization to [compute] when needed.
  static Future<bool> rebuildReaderHtml(
    ReaderArticle article,
    void Function(String htmlUrl) onLoadReaderUrl, {
    required double fontSize,
    required String theme,
    required String fontFamily,
  }) async {
    final sanitized = await HtmlSanitizer.sanitizeAsync(article.content);
    final htmlContent = buildReaderHtml(
      article,
      fontSize: fontSize,
      theme: theme,
      fontFamily: fontFamily,
      sanitizedContent: sanitized,
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
