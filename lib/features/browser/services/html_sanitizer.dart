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
    // FIX(P1.6): allow `/` as attribute separator (HTML permits `<div/onclick=...>`)
    r'''[\s/]on\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''',
    caseSensitive: false,
  );

  static final RegExp _inlineStyleRegex = RegExp(
    // FIX(P1.6): same `/` separator allowance for style attributes
    r'''[\s/]style\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''',
    caseSensitive: false,
  );

  static final RegExp _javascriptDataLinkRegex = RegExp(
    // FIX(P1.6): also block vbscript: scheme
    r'<\s*a\s+[^>]*href\s*=\s*"?\s*(javascript|vbscript|data)\s*:',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _hrefJavascriptRegex = RegExp(
    // FIX(P1.6): also block vbscript: scheme
    r'href\s*=\s*"?\s*(javascript|vbscript)\s*:[^" >]*',
    caseSensitive: false,
  );

  static final RegExp _srcJavascriptRegex = RegExp(
    // FIX(P1.6): also block vbscript: scheme
    r'src\s*=\s*"?\s*(javascript|vbscript|data:text/html)\s*:[^" >]*',
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
    // FIX(P1.6): Decode numeric HTML entities before pattern matching so
    // &#106;avascript: (j) and similar obfuscation is caught.
    result = _decodeNumericEntities(result);
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

  /// Decode numeric character references (decimal &#nnn; and hex &#xhhh;).
  static String _decodeNumericEntities(String input) {
    return input.replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
      final code = int.tryParse(match.group(1) ?? '') ?? 0;
      return code > 0 && code < 0x110000
          ? String.fromCharCode(code)
          : match.group(0)!;
    }).replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (match) {
      final code = int.tryParse(match.group(1) ?? '', radix: 16) ?? 0;
      return code > 0 && code < 0x110000
          ? String.fromCharCode(code)
          : match.group(0)!;
    });
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
