import 'html_sanitizer.dart';
import 'reader_extractor.dart';

/// Composes the HTML document structure and typography styles for Reader Mode.
class ReaderHtmlBuilder {
  static String build({
    required ReaderArticle article,
    required double fontSize,
    required String theme,
    required String fontFamily,
    String? sanitizedContent,
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

    final contentHtml = sanitizedContent ?? HtmlSanitizer.sanitize(article.content);

    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0, user-scalable=yes">
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
      word-wrap: break-word;
    }
    img { max-width: 100%; height: auto; border-radius: 8px; }
    a { color: #3B82F6; text-decoration: underline; }
    h1, h2, h3 { font-family: 'Space Grotesk', sans-serif; line-height: 1.3; }
    p { margin-bottom: 1.2em; }
    .xdm-reader-header { 
      border-bottom: 1px solid ${theme == 'dark' ? '#333' : '#eee'}; 
      padding-bottom: 12px; 
      margin-bottom: 20px; 
    }
    .xdm-reader-meta {
      font-size: 0.85em;
      opacity: 0.7;
      margin-top: 4px;
    }
  </style>
</head>
<body>
  <div class="xdm-reader-header">
    <h1>${HtmlSanitizer.escapeHtml(article.title)}</h1>
    <div class="xdm-reader-meta">
      <span>${HtmlSanitizer.escapeHtml(article.domain)}</span>
      ${article.readingTime > 0 ? ' • <span>${article.readingTime} min read</span>' : ''}
    </div>
  </div>
  $contentHtml
</body>
</html>
''';
  }
}
