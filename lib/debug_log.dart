import 'dart:async';

/// 悬浮球写入的调试日志文件名（与主应用轮询读取共用）。
const String kOverlayDebugLogFileName = 'byvo_overlay_debug.log';

/// SharedPreferences 中保存的 overlay 日志文件完整路径 key，保证主应用与悬浮球读写同一文件。
const String kOverlayDebugLogPathKey = 'byvo_overlay_debug_log_path';

/// 全局调试日志，流式输出供 UI 展示。
///
/// 仅在 debug 模式下使用；release 下可空实现。
class DebugLog {
  DebugLog._();

  static final DebugLog _instance = DebugLog._();
  static DebugLog get instance => _instance;

  final List<String> _lines = [];
  final StreamController<String> _controller = StreamController<String>.broadcast();

  /// 当前全部日志行（只读副本）。
  List<String> get lines => List<String>.unmodifiable(_lines);

  /// 新增日志行流。
  Stream<String> get stream => _controller.stream;

  /// 追加一条日志（带时间戳），并推送到流。最新一条在列表首位（倒序展示）。
  void log(String message) {
    final line = '${DateTime.now().toIso8601String().substring(11, 23)} $message';
    _lines.insert(0, line);
    _controller.add(line);
  }

  /// 打点 API 关键信息：请求/响应摘要，便于在调试窗实时查看。
  void logApi(String tag, String summary) {
    log('[$tag] $summary');
  }

  /// 清空日志（可选：同时通知 UI 刷新）。
  void clear() {
    _lines.clear();
  }

  void dispose() {
    _controller.close();
  }
}
