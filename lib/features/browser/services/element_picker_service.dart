class ElementPickerService {
  static const String pickerScript = r'''
(function() {
  if (window.__xdmPicker) return;
  window.__xdmPicker = true;

  const overlay = document.createElement('div');
  overlay.style.cssText = 'position:fixed;inset:0;z-index:2147483647;cursor:crosshair;';
  const hl = document.createElement('div');
  hl.style.cssText = 'position:absolute;border:2px solid #3B82F6;background:rgba(59,130,246,.2);pointer-events:none;z-index:2147483647;display:none;';
  document.body.append(overlay, hl);

  overlay.addEventListener('mousemove', e => {
    const el = document.elementFromPoint(e.clientX, e.clientY);
    if (!el || el === overlay || el === hl) return;
    const r = el.getBoundingClientRect();
    hl.style.cssText = `display:block;position:absolute;border:2px solid #3B82F6;background:rgba(59,130,246,.2);pointer-events:none;z-index:2147483647;top:${r.top}px;left:${r.left}px;width:${r.width}px;height:${r.height}px;`;
  });

  overlay.addEventListener('click', e => {
    const el = document.elementFromPoint(e.clientX, e.clientY);
    if (el && el !== overlay && el !== hl) {
      const selector = selectorFor(el);
      if (window.XdmPickerChannel) {
        window.XdmPickerChannel.postMessage(JSON.stringify({ selector: selector }));
      }
    }
    cleanup();
  });

  document.addEventListener('keydown', e => { if (e.key === 'Escape') cleanup(); });

  function selectorFor(el) {
    if (el.id) {
      var escapedId = (window.CSS && CSS.escape) ? CSS.escape(el.id) : el.id.replace(/[^a-zA-Z0-9_-]/g, '\\$&');
      return '#' + escapedId;
    }
    let s = el.tagName.toLowerCase();
    if (el.className && typeof el.className === 'string') {
      const classes = el.className.trim().split(/\s+/).filter(Boolean);
      if (classes.length > 0) {
        const cleanClasses = classes.map(c => {
          var clean = c.replace(/[\{\}\(\)\<\>\"\'\\\[\]]/g, '');
          return (window.CSS && CSS.escape) ? CSS.escape(clean) : clean.replace(/[^a-zA-Z0-9_-]/g, '\\$&');
        }).filter(Boolean);
        if (cleanClasses.length > 0) {
          s += '.' + cleanClasses.join('.');
        }
      }
    }
    return s;
  }

  function cleanup() {
    overlay.remove();
    hl.remove();
    window.__xdmPicker = false;
    if (window.XdmPickerChannel) {
      window.XdmPickerChannel.postMessage(JSON.stringify({ action: 'cancel' }));
    }
  }

  setTimeout(function() {
    if (window.__xdmPicker) {
      cleanup();
    }
  }, 60000);

})();
''';

  /// Sanitizes CSS selector to prevent CSS escape breakouts and injection.
  static String sanitizeSelector(String selector) {
    var clean = selector.trim().replaceAll(RegExp(r'[\r\n{}<>]'), '');

    // Strip dangerous function calls and URI schemes
    clean =
        clean.replaceAll(RegExp(r'url\s*\([^)]*\)', caseSensitive: false), '');
    clean = clean.replaceAll(
        RegExp(r'expression\s*\([^)]*\)', caseSensitive: false), '');
    clean = clean.replaceAll(
        RegExp(
            r'@(import|media|supports|charset|namespace|keyframes|font-face)[^;{]*',
            caseSensitive: false),
        '');
    clean = clean.replaceAll(
        RegExp(r'(javascript|data|vbscript)\s*:', caseSensitive: false), '');
    clean = clean.replaceAll(
        RegExp(r'behavior\s*:[^;}]*', caseSensitive: false), '');

    // Collapse whitespace
    clean = clean.replaceAll(RegExp(r'\s+'), ' ').trim();

    // Reject selectors longer than 200 characters
    if (clean.length > 200) return '';

    return clean;
  }

  /// Generates a CSS rule hiding the targeted selector.
  static String blockRule(String selector) {
    final clean = sanitizeSelector(selector);
    if (clean.isEmpty) return '';
    return '$clean { display: none !important; }';
  }

  /// Generates a site-scoped AdBlock cosmetic rule string (e.g. `example.com##selector`).
  static String siteScopedRule(String host, String selector) {
    final cleanHost = host.trim().toLowerCase();
    final cleanSelector = sanitizeSelector(selector);
    if (cleanSelector.isEmpty) return '';
    if (cleanHost.isEmpty) return blockRule(cleanSelector);
    return '$cleanHost##$cleanSelector { display: none !important; }';
  }
}
