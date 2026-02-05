import 'transcription_result.dart';

/// 转写推理引擎抽象。
///
/// 本地模型（SenseVoice、Whisper 等）或未来远程 API 均实现此接口，
/// 上层只依赖 [transcribe] 与 [TranscriptionResult]。
abstract class TranscriptionEngine {
  /// 展示用名称，如 "SenseVoice Small"、"Whisper"、"云端 API"。
  String get displayName;

  /// 是否需要本地模型文件（目录/路径）；若为 false 表示使用远程等，无需选模型目录。
  bool get needsLocalModel => true;

  /// 对 [audioPath] 进行转写。
  ///
  /// [modelSource] 为模型来源：本地时为模型目录路径；远程 API 时可为 null 或由实现忽略。
  Future<TranscriptionResult> transcribe(
    String audioPath, {
    String? modelSource,
  });
}
