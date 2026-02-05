import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'transcription_engine.dart';
import 'transcription_result.dart';

/// 供 [compute] 调用的顶层函数：在 isolate 内执行 SenseVoice 转写，返回 [TranscriptionResult]。
TranscriptionResult transcribeSenseVoiceInIsolate(String modelDir, String audioPath) {
  final OfflineRecognizerResult result = _runSenseVoice(modelDir, audioPath);
  return TranscriptionResult(
    text: result.text,
    emotion: result.emotion.isEmpty ? null : result.emotion,
    event: result.event.isEmpty ? null : result.event,
    lang: result.lang.isEmpty ? null : result.lang,
  );
}

/// SenseVoice（Sherpa-ONNX）本地推理引擎实现。
class SenseVoiceEngine implements TranscriptionEngine {
  @override
  String get displayName => 'SenseVoice Small (阿里)';

  @override
  bool get needsLocalModel => true;

  @override
  Future<TranscriptionResult> transcribe(
    String audioPath, {
    String? modelSource,
  }) async {
    if (modelSource == null || modelSource.isEmpty) {
      throw StateError('SenseVoice 需要模型目录（model.int8.onnx + tokens.txt）');
    }
    return transcribeSenseVoiceInIsolate(modelSource, audioPath);
  }
}

/// 使用 SenseVoice 模型目录 [modelDir] 对 [audioPath] 转写，返回 Sherpa 原始结果。
OfflineRecognizerResult _runSenseVoice(String modelDir, String audioPath) {
    initBindings();
    final String modelPath = '$modelDir${Platform.pathSeparator}model.int8.onnx';
    final String tokensPath = '$modelDir${Platform.pathSeparator}tokens.txt';
    final OfflineSenseVoiceModelConfig senseVoice = OfflineSenseVoiceModelConfig(
      model: modelPath,
      language: 'zh',
      useInverseTextNormalization: true,
    );
    final OfflineModelConfig modelConfig = OfflineModelConfig(
      senseVoice: senseVoice,
      tokens: tokensPath,
      debug: false,
      numThreads: 2,
    );
    final OfflineRecognizerConfig config = OfflineRecognizerConfig(model: modelConfig);
    final OfflineRecognizer recognizer = OfflineRecognizer(config);
    final WaveData waveData = readWave(audioPath);
    final OfflineStream stream = recognizer.createStream();
    stream.acceptWaveform(samples: waveData.samples, sampleRate: waveData.sampleRate);
    recognizer.decode(stream);
    final OfflineRecognizerResult result = recognizer.getResult(stream);
    stream.free();
    recognizer.free();
    return result;
}
