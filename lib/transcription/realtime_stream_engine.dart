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
  bool _stopping = false;

  /// 增量识别文本流。
  Stream<String> get textStream => _textController.stream;

  /// 开始流式转写，连接后端 WS 并开始录音。
  Future<void> start() async {
    if (_recorder != null) return;

    final baseUrl = await loadBackendUrl();
    final wsUrl = backendUrlToWebSocket(baseUrl);
    final uri = Uri.parse('$wsUrl/api/v1/transcribe/stream');

    _recorder = AudioRecorder();
    _stopping = false;

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

    _wsSub = _channel!.stream.listen(
      (message) {
        if (message is! String) return;
        try {
          final json = jsonDecode(message) as Map<String, dynamic>;
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
  }
}
