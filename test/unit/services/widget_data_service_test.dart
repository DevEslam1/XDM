import 'package:dmx/core/services/widget_data_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WidgetDataService on non-iOS', () {
    test('pushStats and forceReload execute safely', () async {
      await WidgetDataService.pushStats(
        activeCount: 2,
        speedBytesPerSec: 5000000,
        completedCount: 10,
      );
      await WidgetDataService.forceReload();
    });
  });
}
