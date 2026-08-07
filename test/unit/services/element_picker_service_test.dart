import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/browser/services/element_picker_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ElementPickerService Unit Tests', () {
    test('blockRule formats CSS selector into display: none !important rule',
        () {
      final rule1 = ElementPickerService.blockRule('#ad-banner');
      expect(rule1, equals('#ad-banner { display: none !important; }'));

      final rule2 = ElementPickerService.blockRule('div.sponsored-post');
      expect(rule2, equals('div.sponsored-post { display: none !important; }'));
    });

    test('pickerScript contains required JS event handlers and namespace', () {
      final js = ElementPickerService.pickerScript;
      expect(js, contains('window.__xdmPicker'));
      expect(js, contains('window.XdmPickerChannel'));
      expect(js, contains('display:none;'));
    });

    test('sanitizeSelector strips breakout characters cleanly', () {
      final clean =
          ElementPickerService.sanitizeSelector('div{color:red}\n#ad');
      expect(clean, equals('divcolor:red#ad'));
    });

    test('siteScopedRule produces AdBlock format rule with host', () {
      final rule =
          ElementPickerService.siteScopedRule('example.com', '.ad-banner');
      expect(rule,
          equals('example.com##.ad-banner { display: none !important; }'));
    });
  });
}
