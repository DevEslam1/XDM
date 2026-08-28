import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('DownloadProvider.tasks is unmodifiable and throws on mutation', () {
    final provider = createMockDownloadProvider();
    final tasks = provider.tasks;

    expect(
      () => tasks.add(createTestTask(id: '1')),
      throwsUnsupportedError,
    );
  });
}
