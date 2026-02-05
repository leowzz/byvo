/// 与具体引擎无关的转写结果。
///
/// 文本必选；情感、环境音、语种等为可选，由引擎能力决定（如 SenseVoice 有，未来 API 可能无）。
class TranscriptionResult {
  const TranscriptionResult({
    required this.text,
    this.emotion,
    this.event,
    this.lang,
  });

  /// 转写文本
  final String text;

  /// 情感标签（若引擎支持，如 SenseVoice）
  final String? emotion;

  /// 环境音/事件标签（若引擎支持）
  final String? event;

  /// 语种（若引擎支持）
  final String? lang;
}
