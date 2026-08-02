import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class ElementPickerService {
  static const _pickerJs = '''
(function() {
  if (window.__xdmPickerActive) return;
  window.__xdmPickerActive = true;

  let overlay = document.createElement('div');
  overlay.id = '__xdm_picker_overlay';
  overlay.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;z-index:2147483647;cursor:crosshair;';
  document.body.appendChild(overlay);

  let highlight = document.createElement('div');
  highlight.id = '__xdm_picker_highlight';
  highlight.style.cssText = 'position:absolute;border:2px solid #3B82F6;background:rgba(59,130,246,0.2);pointer-events:none;z-index:2147483647;display:none;';
  document.body.appendChild(highlight);

  overlay.addEventListener('mousemove', function(e) {
    const el = document.elementFromPoint(e.clientX, e.clientY);
    if (el && el !== overlay && el !== highlight) {
      const rect = el.getBoundingClientRect();
      highlight.style.display = 'block';
      highlight.style.top = rect.top + 'px';
      highlight.style.left = rect.left + 'px';
      highlight.style.width = rect.width + 'px';
      highlight.style.height = rect.height + 'px';
    }
  });

  overlay.addEventListener('click', function(e) {
    const el = document.elementFromPoint(e.clientX, e.clientY);
    if (el && el !== overlay && el !== highlight) {
      const selector = generateSelector(el);
      cleanup();
    }
  });

  function generateSelector(el) {
    if (el.id) return '#' + el.id;
    let path = el.tagName.toLowerCase();
    if (el.className && typeof el.className === 'string') {
      path += '.' + el.className.trim().split(/\\s+/).join('.');
    }
    return path;
  }

  function cleanup() {
    overlay.remove();
    highlight.remove();
    window.__xdmPickerActive = false;
  }
})();
''';

  static Future<void> activate(PlatformWebViewController controller) async {
    await controller.runJavaScript(_pickerJs);
  }

  static String generateBlockRule(Map<String, dynamic> result) {
    final selector = result['selector'] as String? ?? '';
    if (selector.isEmpty) return '';
    return '$selector { display: none !important; }';
  }
}
