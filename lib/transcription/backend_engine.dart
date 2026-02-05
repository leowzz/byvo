import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/backend_config.dart';
import 'transcription_engine.dart';
import 'transcription_result.dart';

/// 后端转写引擎，将音频 POST 到 FastAPI 后端，支持 sensevoice / volcengine。
class BackendTranscriptionEngine implements TranscriptionEngine {
  BackendTranscriptionEngine({required this.engine});

  /// 引擎类型：sensevoice | volcengine
  final String engine;

  @override
  String get displayName => engine == 'sensevoice' ? 'SenseVoice (后端)' : '豆包 (后端)';

  @override
  bool get needsLocalModel => false;

  @override
  Future<TranscriptionResult> transcribe(
    String audioPath, {
    String? modelSource,
  }) async {
    final baseUrl = await loadBackendUrl();
    final uri = Uri.parse('$baseUrl/api/v1/transcribe');
    final file = File(audioPath);
    if (!await file.exists()) {
      throw StateError('音频文件不存在: $audioPath');
    }
    final request = http.MultipartRequest('POST', uri)
      ..files.add(await http.MultipartFile.fromPath('audio', audioPath))
      ..fields['engine'] = engine;

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode != 200) {
      final body = response.body;
      throw Exception('后端转写失败: ${response.statusCode} $body');
    }

    final json = _parseJson(response.body);
    return TranscriptionResult(
      text: json['text'] as String? ?? '',
      emotion: json['emotion'] as String?,
      event: json['event'] as String?,
      lang: json['lang'] as String?,
    );
  }

  Map<String, dynamic> _parseJson(String body) {
    if (body.isEmpty) return <String, dynamic>{};
    return jsonDecode(body) as Map<String, dynamic>;
  }
}
