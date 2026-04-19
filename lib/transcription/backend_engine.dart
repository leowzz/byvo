import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:talker_dio_logger/talker_dio_logger.dart';

import '../app_talker.dart';
import '../config/backend_config.dart';
import 'transcription_engine.dart';
import 'transcription_result.dart';

/// 后端转写引擎：音频 POST 到 FastAPI，豆包 ASR。
class BackendTranscriptionEngine implements TranscriptionEngine {
  const BackendTranscriptionEngine();

  static final Dio _dio = Dio()
    ..interceptors.addAll(<Interceptor>[
      if (kDebugMode) TalkerDioLogger(talker: appTalker),
    ]);

  @override
  String get displayName => '豆包';

  @override
  bool get needsLocalModel => false;

  @override
  Future<TranscriptionResult> transcribe(
    String audioPath, {
    String? modelSource,
    bool effect = false,
    bool useLlm = false,
  }) async {
    final baseUrl = await loadBackendUrl();
    if (baseUrl.trim().isEmpty) {
      throw StateError('请先配置后端地址');
    }
    final apiKey = await loadBackendApiKey();
    if (apiKey.trim().isEmpty) {
      throw StateError('请先配置 API Key');
    }
    final uri = Uri.parse('$baseUrl/api/v1/transcribe').replace(
      queryParameters: <String, String>{
        'effect': effect ? 'true' : 'false',
        'use_llm': useLlm ? 'true' : 'false',
      },
    );
    final file = File(audioPath);
    if (!await file.exists()) {
      throw StateError('音频文件不存在: $audioPath');
    }
    logInfo('[转写] POST $uri');
    late final Response<String> response;
    try {
      response = await _dio.post<String>(
        uri.toString(),
        data: FormData.fromMap(<String, Object>{
          'audio': await MultipartFile.fromFile(audioPath),
        }),
        options: Options(
          headers: <String, String>{'X-API-Key': apiKey.trim()},
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e, st) {
      logError(e, st, '[转写] 请求失败');
      rethrow;
    }
    final body = response.data ?? '';

    if (response.statusCode == 401) {
      logWarning('[转写] 401 $body');
      throw StateError('后端认证失败：请检查 API Key');
    }
    if (response.statusCode != 200) {
      logWarning('[转写] ${response.statusCode} $body');
      throw Exception('后端转写失败: ${response.statusCode} $body');
    }

    final json = _parseJson(body);
    final text = json['text'] as String? ?? '';
    final emotion = json['emotion'] as String?;
    final event = json['event'] as String?;
    final lang = json['lang'] as String?;
    logInfo(
      '[转写] 200 OK | text=${text.length}字 emotion=$emotion event=$event lang=$lang',
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
