import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 后端 API 地址
const String _keyBackendUrl = 'backend_url';
const String _keyBackendApiKey = 'backend_api_key';

const String kDefaultBackendUrl = '';

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

/// 从 SharedPreferences 读取后端 API key。
Future<String> loadBackendApiKey() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_keyBackendApiKey) ?? '';
}

/// 保存后端 API key。
Future<void> saveBackendApiKey(String value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_keyBackendApiKey, value);
}

const String _keyEffectTranscribe = 'effect_transcribe';

/// 是否开启效果转写（去口语化/语义顺滑）。
Future<bool> loadEffectTranscribe() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_keyEffectTranscribe) ?? false;
}

/// 保存效果转写开关。
Future<void> saveEffectTranscribe(bool value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_keyEffectTranscribe, value);
}

const String _keyIdleTimeoutSec = 'transcribe_idle_timeout_sec';

/// 无新识别内容超过该秒数则断开连接（默认 30）。
Future<int> loadIdleTimeoutSec() async {
  final prefs = await SharedPreferences.getInstance();
  final v = prefs.getInt(_keyIdleTimeoutSec);
  return v ?? 30;
}

/// 保存无文本断开秒数。
Future<void> saveIdleTimeoutSec(int value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_keyIdleTimeoutSec, value);
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

Future<void> verifyBackendConnection({
  required String baseUrl,
  required String apiKey,
}) async {
  final normalizedBaseUrl = baseUrl.trim();
  final normalizedApiKey = apiKey.trim();
  if (normalizedBaseUrl.isEmpty) {
    throw StateError('请输入后端地址');
  }
  if (normalizedApiKey.isEmpty) {
    throw StateError('请输入 API Key');
  }

  final dio = Dio();
  try {
    final response = await dio.get<Map<String, dynamic>>(
      '$normalizedBaseUrl/api/v1/auth-check',
      options: Options(
        headers: <String, String>{'X-API-Key': normalizedApiKey},
        validateStatus: (_) => true,
      ),
    );
    if (response.statusCode == 200) {
      return;
    }
    if (response.statusCode == 401) {
      throw StateError('API Key 无效');
    }
    throw StateError('连接测试失败: ${response.statusCode}');
  } on DioException catch (e) {
    throw StateError('连接测试失败: ${e.message ?? '无法连接到服务端'}');
  }
}
