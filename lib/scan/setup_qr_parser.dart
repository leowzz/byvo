class ByvoSetupConfig {
  const ByvoSetupConfig({
    required this.baseUrl,
    required this.apiKey,
  });

  final String baseUrl;
  final String apiKey;
}

ByvoSetupConfig parseByvoSetupUri(String raw) {
  final uri = Uri.parse(raw);
  if (uri.scheme != 'byvo' || uri.host != 'setup') {
    throw const FormatException('不是有效的 byvo 配置码');
  }

  final baseUrl = uri.queryParameters['base_url']?.trim() ?? '';
  final apiKey = uri.queryParameters['api_key']?.trim() ?? '';
  if (baseUrl.isEmpty || apiKey.isEmpty) {
    throw const FormatException('配置码不完整');
  }

  return ByvoSetupConfig(baseUrl: baseUrl, apiKey: apiKey);
}
