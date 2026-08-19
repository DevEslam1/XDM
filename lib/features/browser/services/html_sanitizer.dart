import 'package:flutter/foundation.dart';

/// Pure, isolate-safe HTML sanitizer.
/// Removes dangerous tags, inline event handlers, and malicious URIs
/// to protect Reader Mode from XSS attacks while preserving formatting.
class HtmlSanitizer {
  // Pre-compiled regex patterns to avoid recompilation per call
  static final RegExp _dangerousTagBlockRegex = RegExp(
    r'<\s*(script|iframe|object|embed|style|form|link|applet|base|meta|svg)\b[^>]*>.*?<\s*/\s*\1\s*>',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _dangerousSelfClosingRegex = RegExp(
    r'<\s*(script|iframe|object|embed|style|form|link|applet|base|meta|svg)\b[^>]*/?>',
    caseSensitive: false,
  );

  static final RegExp _inlineEventHandlerRegex = RegExp(
    r'''\son\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''',
    caseSensitive: false,
  );

  static final RegExp _inlineStyleRegex = RegExp(
    r'''\sstyle\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''',
    caseSensitive: false,
  );

  static final RegExp _javascriptDataLinkRegex = RegExp(
    r'<\s*a\s+[^>]*href\s*=\s*"?\s*(javascript|data)\s*:',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _hrefJavascriptRegex = RegExp(
    r'href\s*=\s*"?\s*javascript\s*:[^" >]*',
    caseSensitive: false,
  );

  static final RegExp _srcJavascriptRegex = RegExp(
    r'src\s*=\s*"?\s*(javascript|data:text/html)\s*:[^" >]*',
    caseSensitive: false,
  );

  static final RegExp _imgOnErrorRegex = RegExp(
    r'<\s*img\b[^>]*\bonerror\b[^>]*>',
    caseSensitive: false,
  );

  /// Synchronous pure sanitization method.
  static String sanitize(String htmlText) {
    if (htmlText.isEmpty) return '';

    var result = htmlText;
    // Multi-pass tag removal to prevent evasion via nesting (e.g., <scr<script>ipt>)
    for (var pass = 0; pass < 2; pass++) {
      result = result
          .replaceAll(_dangerousTagBlockRegex, '')
          .replaceAll(_dangerousSelfClosingRegex, '');
    }

    result = result
        .replaceAll(_inlineEventHandlerRegex, '')
        .replaceAll(_inlineStyleRegex, '')
        .replaceAll(_javascriptDataLinkRegex, '<a>')
        .replaceAll(_hrefJavascriptRegex, 'href="#"')
        .replaceAll(_srcJavascriptRegex, 'src=""')
        .replaceAll(_imgOnErrorRegex, '');

    return result;
  }

  /// Asynchronous sanitization offloaded to a background isolate via [compute].
  static Future<String> sanitizeAsync(String htmlText) async {
    if (htmlText.length < 2048) {
      // Small HTML strings don't incur thread handoff overhead
      return sanitize(htmlText);
    }
    return compute(sanitize, htmlText);
  }

  /// Escapes text for safe inclusion in HTML body/attributes.
  static String escapeHtml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }
}
