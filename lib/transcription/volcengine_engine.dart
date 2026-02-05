import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';

import '../config/volcengine_config.dart';
import 'transcription_engine.dart';
import 'transcription_result.dart';

/// 豆包大模型流式语音识别（远程 API）引擎。
///
/// 使用 WebSocket 协议：建连鉴权 → full client request → audio-only 分包 → 收 full server response。
class VolcengineEngine implements TranscriptionEngine {
  VolcengineEngine();

  @override
  String get displayName => '豆包语音（远程）';

  @override
  bool get needsLocalModel => false;

  static const String _wssUrl =
      'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream';

  /// WebSocket 建连时带鉴权 Header（豆包 API 要求）。
  static IOWebSocketChannel _connectWithHeaders(VolcengineCredentials cred) {
    return IOWebSocketChannel.connect(
      Uri.parse(_wssUrl),
      headers: <String, dynamic>{
        'X-Api-App-Key': cred.appKey,
        'X-Api-Access-Key': cred.accessKey,
        'X-Api-Resource-Id': cred.resourceId,
        'X-Api-Connect-Id': _uuid(),
      },
    );
  }

  @override
  Future<TranscriptionResult> transcribe(
    String audioPath, {
    String? modelSource,
  }) async {
    final VolcengineCredentials cred = await loadVolcengineCredentials();
    if (!cred.isValid) {
      throw StateError(
        '豆包 API 未配置，请在设置中填写 App Key、Access Key、Resource ID',
      );
    }

    final WavPcm pcm = await _readWavTo16kMono(audioPath);
    final IOWebSocketChannel channel = _connectWithHeaders(cred);
    try {
      await channel.ready;
      await _sendFullClientRequest(channel);
      await _sendAudioChunks(channel, pcm.bytes);
      final String text = await _receiveFinalResult(channel);
      return TranscriptionResult(text: text);
    } finally {
      await channel.sink.close();
    }
  }

  static String _uuid() {
    return '${DateTime.now().millisecondsSinceEpoch}-${(DateTime.now().microsecondsSinceEpoch % 100000).toString().padLeft(5, '0')}';
  }

  /// 4 字节 header：version|header_size, message_type|flags, serialization|compression, reserved
  static const int _headerFullClient = 0x11_10_10_00;
  static const int _headerAudioOnly = 0x11_20_00_00;
  static const int _headerAudioLast = 0x11_22_00_00;

  static void _writeHeader(Uint8List buf, int header) {
    buf[0] = (header >> 24) & 0xff;
    buf[1] = (header >> 16) & 0xff;
    buf[2] = (header >> 8) & 0xff;
    buf[3] = header & 0xff;
  }

  static void _writePayloadSize(Uint8List buf, int offset, int size) {
    buf[offset] = (size >> 24) & 0xff;
    buf[offset + 1] = (size >> 16) & 0xff;
    buf[offset + 2] = (size >> 8) & 0xff;
    buf[offset + 3] = size & 0xff;
  }

  Future<void> _sendFullClientRequest(IOWebSocketChannel channel) async {
    final Map<String, dynamic> body = {
      'audio': {
        'format': 'pcm',
        'codec': 'raw',
        'rate': 16000,
        'bits': 16,
        'channel': 1,
      },
      'request': {
        'model_name': 'bigmodel',
        'enable_itn': true,
        'enable_punc': true,
      },
    };
    final Uint8List jsonBytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    final int total = 4 + 4 + jsonBytes.length;
    final Uint8List packet = Uint8List(total);
    _writeHeader(packet, _headerFullClient);
    _writePayloadSize(packet, 4, jsonBytes.length);
    packet.setRange(8, 8 + jsonBytes.length, jsonBytes);
    channel.sink.add(packet);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  /// 每包约 200ms：16000 * 0.2 * 2 = 6400 字节
  static const int _chunkSamples = 3200; // 200ms at 16k
  static const int _chunkBytes = _chunkSamples * 2;

  Future<void> _sendAudioChunks(
    IOWebSocketChannel channel,
    Uint8List pcm,
  ) async {
    int offset = 0;
    while (offset < pcm.length) {
      final int remaining = pcm.length - offset;
      final bool isLast = remaining <= _chunkBytes;
      final int take = isLast ? remaining : _chunkBytes;
      final int header = isLast ? _headerAudioLast : _headerAudioOnly;
      final int total = 4 + 4 + take;
      final Uint8List packet = Uint8List(total);
      _writeHeader(packet, header);
      _writePayloadSize(packet, 4, take);
      packet.setRange(8, 8 + take, pcm, offset);
      channel.sink.add(packet);
      offset += take;
      if (!isLast) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  /// 解析 full server response：Header(4) + Sequence(4) + Payload size(4) + Payload。
  /// 遇 error 消息或最后一包(flags 0b0011)或超时则结束。
  Future<String> _receiveFinalResult(IOWebSocketChannel channel) async {
    const Duration timeout = Duration(seconds: 30);
    final StringBuffer text = StringBuffer();
    final Stream<dynamic> stream = channel.stream.timeout(
      timeout,
      onTimeout: (EventSink<dynamic> sink) {
        sink.close();
      },
    );
    await for (final dynamic message in stream) {
      if (message is! Uint8List && message is! List<int>) continue;
      final Uint8List data = message is Uint8List
          ? message
          : Uint8List.fromList(message as List<int>);
      if (data.length < 4) continue;
      final int messageType = (data[1] >> 4) & 0x0f;
      final int flags = data[1] & 0x0f;
      if (messageType == 0x0f) {
        final int code = data.length >= 8
            ? (data[4] << 24) | (data[5] << 16) | (data[6] << 8) | data[7]
            : 0;
        throw Exception('豆包 API 错误: code=$code');
      }
      if (messageType != 0x09) continue;
      if (data.length < 12) continue;
      final int payloadSize = (data[8] << 24) |
          (data[9] << 16) |
          (data[10] << 8) |
          data[11];
      if (data.length < 12 + payloadSize) continue;
      final String jsonStr = utf8.decode(data.sublist(12, 12 + payloadSize));
      try {
        final Map<String, dynamic> json = jsonDecode(jsonStr) as Map<String, dynamic>;
        final dynamic resultRaw = json['result'];
        String? t;
        if (resultRaw is Map<String, dynamic>) {
          t = resultRaw['text'] as String?;
        } else if (resultRaw is String) {
          t = resultRaw;
        }
        if (t != null && t.isNotEmpty) text.write(t);
      } catch (_) {}
      if (flags == 0x03) break;
    }
    return text.toString().trim();
  }

  Future<WavPcm> _readWavTo16kMono(String path) async {
    final File file = File(path);
    final Uint8List raw = await file.readAsBytes();
    final WavInfo info = _parseWavHeader(raw);
    Uint8List pcm = raw.sublist(info.dataOffset, raw.length);
    if (info.channels == 2) {
      pcm = _stereoToMono16(pcm);
    }
    if (info.sampleRate != 16000) {
      pcm = _resample16(pcm, info.sampleRate, 16000);
    }
    return WavPcm(pcm, 16000);
  }

  static WavInfo _parseWavHeader(Uint8List raw) {
    if (raw.length < 44) throw FormatException('WAV too short');
    if (raw[0] != 0x52 || raw[1] != 0x49) throw FormatException('Not RIFF');
    int sampleRate = 16000;
    int channels = 1;
    int dataOffset = -1;
    int offset = 12;
    while (offset + 8 <= raw.length) {
      final String chunkId = String.fromCharCodes(raw.sublist(offset, offset + 4));
      final int chunkSize = raw[offset + 4] | (raw[offset + 5] << 8) |
          (raw[offset + 6] << 16) | (raw[offset + 7] << 24);
      if (chunkId == 'fmt ') {
        if (chunkSize >= 16) {
          channels = raw[offset + 10] | (raw[offset + 11] << 8);
          sampleRate = raw[offset + 12] | (raw[offset + 13] << 8) |
              (raw[offset + 14] << 16) | (raw[offset + 15] << 24);
        }
      } else if (chunkId == 'data') {
        dataOffset = offset + 8;
        break;
      }
      offset += 8 + chunkSize;
    }
    if (dataOffset < 0) throw FormatException('WAV data chunk not found');
    return WavInfo(
      dataOffset: dataOffset,
      sampleRate: sampleRate,
      channels: channels,
    );
  }

  /// 立体声 16bit：取左声道 (L R L R ... -> L L ...)
  static Uint8List _stereoToMono16(Uint8List stereo) {
    final int outLen = stereo.length ~/ 2;
    final Uint8List mono = Uint8List(outLen);
    for (int i = 0; i < outLen; i += 2) {
      final int src = i * 2;
      mono[i] = stereo[src];
      mono[i + 1] = stereo[src + 1];
    }
    return mono;
  }

  static Uint8List _resample16(Uint8List pcm, int fromRate, int toRate) {
    final int inSamples = pcm.length ~/ 2;
    final int outSamples = (inSamples * toRate / fromRate).round();
    final Uint8List out = Uint8List(outSamples * 2);
    final ByteData inData = ByteData.view(pcm.buffer, pcm.offsetInBytes, pcm.length);
    final ByteData outData = ByteData.view(out.buffer, out.offsetInBytes, out.length);
    for (int i = 0; i < outSamples; i++) {
      final double srcIdx = i * fromRate / toRate;
      final int i0 = srcIdx.floor().clamp(0, inSamples - 1);
      final int i1 = (i0 + 1).clamp(0, inSamples - 1);
      final double frac = srcIdx - i0;
      final int s0 = inData.getInt16(i0 * 2, Endian.little);
      final int s1 = inData.getInt16(i1 * 2, Endian.little);
      final int s = (s0 + (s1 - s0) * frac).round().clamp(-32768, 32767);
      outData.setInt16(i * 2, s, Endian.little);
    }
    return out;
  }
}

class WavPcm {
  WavPcm(this.bytes, this.sampleRate);
  final Uint8List bytes;
  final int sampleRate;
}

class WavInfo {
  WavInfo({
    required this.dataOffset,
    required this.sampleRate,
    required this.channels,
  });
  final int dataOffset;
  final int sampleRate;
  final int channels;
}
