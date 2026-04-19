import 'package:byvo/scan/setup_qr_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses valid byvo setup uri', () {
    final result = parseByvoSetupUri(
      'byvo://setup?base_url=http%3A%2F%2F192.168.1.20%3A8000&api_key=demo-key',
    );

    expect(result.baseUrl, 'http://192.168.1.20:8000');
    expect(result.apiKey, 'demo-key');
  });

  test('rejects non-byvo scheme', () {
    expect(
      () => parseByvoSetupUri('https://example.com?a=1'),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects missing api key', () {
    expect(
      () => parseByvoSetupUri('byvo://setup?base_url=http%3A%2F%2F127.0.0.1%3A8000'),
      throwsA(isA<FormatException>()),
    );
  });
}
