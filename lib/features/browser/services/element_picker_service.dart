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
    hl.style.cssText += `display:block;top:${r.top}px;left:${r.left}px;width:${r.width}px;height:${r.height}px;`;
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
    if (el.id) return '#' + CSS.escape(el.id);
    let s = el.tagName.toLowerCase();
    if (el.className && typeof el.className === 'string') {
      const classes = el.className.trim().split(/\s+/).filter(Boolean);
      if (classes.length > 0) {
        s += '.' + classes.map(c => CSS.escape(c)).join('.');
      }
    }
    return s;
  }

  function cleanup() {
    overlay.remove();
    hl.remove();
    window.__xdmPicker = false;
  }
})();
''';

  /// Generates a site-scoped CSS rule hiding the targeted selector.
  static String blockRule(String selector) {
    final clean = selector.trim();
    return '$clean { display: none !important; }';
  }
}
