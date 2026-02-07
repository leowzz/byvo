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
  /// [effect] 是否开启效果转写（去口语化/语义顺滑），仅后端豆包等支持时有效。
  /// [useLlm] 是否启用 LLM 纠错，由后端配置决定；开启「LLM处理」开关时传 true。
  Future<TranscriptionResult> transcribe(
    String audioPath, {
    String? modelSource,
    bool effect = false,
    bool useLlm = false,
  });
}
