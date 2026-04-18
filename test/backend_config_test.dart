import 'package:byvo/config/backend_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('loadBackendApiKey returns empty by default', () async {
    expect(await loadBackendApiKey(), '');
  });

  test('saveBackendApiKey persists the value', () async {
    await saveBackendApiKey('demo-key');

    expect(await loadBackendApiKey(), 'demo-key');
  });
}
