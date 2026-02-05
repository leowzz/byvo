import 'package:shared_preferences/shared_preferences.dart';

/// 后端 API 地址，默认 Android 模拟器可用 10.0.2.2:8000
const String _keyBackendUrl = 'backend_url';

const String kDefaultBackendUrl = 'http://10.0.2.2:8000';

/// 从 SharedPreferences 读取后端 base URL。
Future<String> loadBackendUrl() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_keyBackendUrl) ?? kDefaultBackendUrl;
}

/// 保存后端 base URL。
Future<void> saveBackendUrl(String url) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_keyBackendUrl, url);
}

/// 将 HTTP(S) base URL 转为 WebSocket URL。
String backendUrlToWebSocket(String baseUrl) {
  if (baseUrl.startsWith('https://')) {
    return baseUrl.replaceFirst('https://', 'wss://');
  }
  if (baseUrl.startsWith('http://')) {
    return baseUrl.replaceFirst('http://', 'ws://');
  }
  return 'ws://$baseUrl';
}
