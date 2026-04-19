import 'package:byvo/config/backend_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _TrackingPreferencesStore extends InMemorySharedPreferencesStore {
  _TrackingPreferencesStore.withData(super.data) : super.withData();

  int getAllCallCount = 0;

  @override
  Future<Map<String, Object>> getAll() async {
    getAllCallCount += 1;
    return super.getAll();
  }
}

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

  test('loadBackendUrl reloads preferences before reading', () async {
    final store = _TrackingPreferencesStore.withData(<String, Object>{
      'flutter.backend_url': 'http://10.0.2.2:8000',
    });
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.resetStatic();

    expect(await loadBackendUrl(), 'http://10.0.2.2:8000');
    expect(store.getAllCallCount, 2);
  });

  test('loadBackendApiKey reloads preferences before reading', () async {
    final store = _TrackingPreferencesStore.withData(<String, Object>{
      'flutter.backend_api_key': 'demo-key',
    });
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.resetStatic();

    expect(await loadBackendApiKey(), 'demo-key');
    expect(store.getAllCallCount, 2);
  });
}
