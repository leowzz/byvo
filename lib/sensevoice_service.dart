import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart';

/// 使用 SenseVoice 模型目录 [modelDir]（内含 model.int8.onnx 与 tokens.txt）对 [audioPath] 进行转写。
/// 返回 [OfflineRecognizerResult]，含 text、emotion、event、lang 等。
OfflineRecognizerResult transcribeWithSenseVoice(String modelDir, String audioPath) {
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
