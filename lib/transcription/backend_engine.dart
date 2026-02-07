import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/backend_config.dart';
import '../debug_log.dart';
import 'transcription_engine.dart';
import 'transcription_result.dart';

/// 后端转写引擎：音频 POST 到 FastAPI，豆包 ASR。
class BackendTranscriptionEngine implements TranscriptionEngine {
  const BackendTranscriptionEngine();

  @override
  String get displayName => '豆包';

  @override
  bool get needsLocalModel => false;

  @override
  Future<TranscriptionResult> transcribe(
    String audioPath, {
    String? modelSource,
    bool effect = false,
  }) async {
    final baseUrl = await loadBackendUrl();
    final uri = Uri.parse('$baseUrl/api/v1/transcribe').replace(
      queryParameters: <String, String>{'effect': effect ? 'true' : 'false'},
    );
    final file = File(audioPath);
    if (!await file.exists()) {
      throw StateError('音频文件不存在: $audioPath');
    }
    DebugLog.instance.logApi('转写', 'POST $uri');
    final request = http.MultipartRequest('POST', uri)
      ..files.add(await http.MultipartFile.fromPath('audio', audioPath));

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    final body = response.body;

    if (response.statusCode != 200) {
      DebugLog.instance.logApi('转写', '${response.statusCode} $body');
      throw Exception('后端转写失败: ${response.statusCode} $body');
    }

    final json = _parseJson(body);
    final text = json['text'] as String? ?? '';
    final emotion = json['emotion'] as String?;
    final event = json['event'] as String?;
    final lang = json['lang'] as String?;
    DebugLog.instance.logApi(
      '转写',
      '200 OK | text=${text.length}字 emotion=$emotion event=$event lang=$lang',
    );
    return TranscriptionResult(
      text: text,
      emotion: emotion,
      event: event,
      lang: lang,
    );
  }

  Map<String, dynamic> _parseJson(String body) {
    if (body.isEmpty) return <String, dynamic>{};
    return jsonDecode(body) as Map<String, dynamic>;
  }
}
