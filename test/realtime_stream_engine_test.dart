import 'package:byvo/transcription/realtime_stream_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps close code 1008 to auth error message', () {
    final message = RealtimeStreamEngine.closeErrorMessageForCode(
      1008,
      'invalid api key',
    );

    expect(message, contains('认证失败'));
  });

  test('does not map non-auth close codes', () {
    final message =
        RealtimeStreamEngine.closeErrorMessageForCode(1000, 'normal');

    expect(message, isNull);
  });
}
