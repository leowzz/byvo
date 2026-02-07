import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/backend_config.dart';
import '../debug_log.dart';

/// 实时流式转写：record.startStream + WebSocket 推送 PCM 到后端。
///
/// 使用豆包流式 API，边录边发边收，无分块间隙。
class RealtimeStreamEngine {
  RealtimeStreamEngine();

  static const int _chunkBytes = 6400; // 200ms at 16k/16bit mono

  AudioRecorder? _recorder;
  WebSocketChannel? _channel;
  StreamSubscription<Uint8List>? _recordSub;
  StreamSubscription? _wsSub;
  final StreamController<String> _textController = StreamController<String>.broadcast();
  final StreamController<void> _connectionClosedController = StreamController<void>.broadcast();
  bool _stopping = false;
  bool _connectionClosedEmitted = false;
  DateTime? _lastAudioSentAt;
  DateTime? _lastResponseAt;

  /// 增量识别文本流。
  Stream<String> get textStream => _textController.stream;

  /// 连接已关闭（服务端空闲超时或断开等），仅触发一次。
  Stream<void> get connectionClosedStream => _connectionClosedController.stream;

  /// 是否已发送完毕：已连接且连续 1 秒无音频发送且 1 秒无服务端返回。
  bool get isDrainComplete {
    if (_lastAudioSentAt == null || _lastResponseAt == null) return false;
    final now = DateTime.now();
    const d = Duration(seconds: 1);
    return now.difference(_lastAudioSentAt!) >= d && now.difference(_lastResponseAt!) >= d;
  }

  /// 开始流式转写，连接后端 WS 并开始录音。
  ///
  /// [effect] 是否开启效果转写（去口语化/语义顺滑）。
  /// [useLlm] 是否启用 LLM 纠错，由后端配置决定；开启「LLM处理」开关时传 true。
  /// [idleTimeoutSec] 无新识别内容超过该秒数则断开；不传则用服务端配置。
  Future<void> start({
    bool effect = false,
    bool useLlm = false,
    int? idleTimeoutSec,
  }) async {
    if (_recorder != null) return;

    final baseUrl = await loadBackendUrl();
    final wsUrl = backendUrlToWebSocket(baseUrl);
    final params = <String, String>{
      'effect': effect ? 'true' : 'false',
      'use_llm': useLlm ? 'true' : 'false',
    };
    if (idleTimeoutSec != null && idleTimeoutSec > 0) {
      params['idle_timeout_sec'] = idleTimeoutSec.toString();
    }
    final uri = Uri.parse('$wsUrl/api/v1/transcribe/stream').replace(
      queryParameters: params,
    );

    _recorder = AudioRecorder();
    _stopping = false;
    _lastAudioSentAt = DateTime.now();
    _lastResponseAt = DateTime.now();

    DebugLog.instance.logApi('实时', 'WS connect $uri');
    _channel = WebSocketChannel.connect(uri);
    await _channel!.ready;
    DebugLog.instance.logApi('实时', 'WS connected');

    final stream = await _recorder!.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );

    final buffer = <int>[];

    _recordSub = stream.listen(
      (Uint8List data) {
        if (_stopping) return;
        buffer.addAll(data);
        while (buffer.length >= _chunkBytes) {
          final chunk = Uint8List.fromList(buffer.take(_chunkBytes).toList());
          buffer.removeRange(0, _chunkBytes);
          _channel?.sink.add(chunk);
          _lastAudioSentAt = DateTime.now();
        }
      },
      onDone: () {
        if (buffer.isNotEmpty) {
          _channel?.sink.add(Uint8List.fromList(buffer));
        }
        _channel?.sink.close();
      },
      onError: (e, st) {
        _textController.addError(e, st);
      },
    );

    _connectionClosedEmitted = false;
    _wsSub = _channel!.stream.listen(
      (message) {
        _lastResponseAt = DateTime.now();
        if (message is! String) return;
        try {
          final json = jsonDecode(message) as Map<String, dynamic>;
          if (json['closed'] == true) {
            DebugLog.instance.logApi('实时', '<- closed: ${json['reason']}');
            _emitConnectionClosed();
            return;
          }
          final text = json['text'] as String?;
          if (text != null) {
            DebugLog.instance.logApi('实时', '<- text: ${text.length}字 "${_truncate(text, 40)}"');
            _textController.add(text);
          } else {
            DebugLog.instance.logApi('实时', '<- $message');
          }
        } catch (_) {
          DebugLog.instance.logApi('实时', '<- raw $message');
        }
      },
      onDone: () {
        DebugLog.instance.logApi('实时', 'WS closed');
        _emitConnectionClosed();
      },
      onError: (e) {
        DebugLog.instance.logApi('实时', 'error $e');
        if (!_textController.isClosed) {
          _textController.addError(e);
        }
      },
    );
  }

  static String _truncate(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen)}…';
  }

  void _emitConnectionClosed() {
    if (_connectionClosedEmitted) return;
    _connectionClosedEmitted = true;
    if (!_connectionClosedController.isClosed) {
      _connectionClosedController.add(null);
    }
  }

  /// 停止转写，关闭录音与 WebSocket。
  Future<void> stop() async {
    DebugLog.instance.logApi('实时', 'stop');
    _stopping = true;
    await _recordSub?.cancel();
    await _recorder?.stop();
    _recorder = null;
    await _channel?.sink.close();
    await _wsSub?.cancel();
    _channel = null;
  }

  /// 释放资源。
  void dispose() {
    _textController.close();
    _connectionClosedController.close();
  }
}
