import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'sensevoice_model_loader.dart';
import 'transcription/sensevoice_engine.dart';
import 'transcription/transcription_engine.dart';
import 'transcription/transcription_result.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'byvo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const TranscriptionMvpPage(),
    );
  }
}

class TranscriptionMvpPage extends StatefulWidget {
  const TranscriptionMvpPage({super.key});

  @override
  State<TranscriptionMvpPage> createState() => _TranscriptionMvpPageState();
}

class _TranscriptionMvpPageState extends State<TranscriptionMvpPage> {
  /// 当前推理引擎（可替换为 Whisper、API 等）
  final TranscriptionEngine _engine = SenseVoiceEngine();

  String? _modelDir;
  String? _audioPath;
  bool _isTranscribing = false;
  TranscriptionResult? _result;
  String? _error;
  bool _isRecording = false;
  bool _isRealtimeTranscribing = false;
  String _realtimeText = '';
  final AudioRecorder _recorder = AudioRecorder();

  @override
  void initState() {
    super.initState();
    if (_engine.needsLocalModel && _engine is SenseVoiceEngine) {
      _loadModelFromAssets();
    }
  }

  Future<void> _loadModelFromAssets() async {
    if (_engine is! SenseVoiceEngine) return;
    final String? dir = await ensureSenseVoiceModelFromAssets();
    if (dir != null && mounted) {
      setState(() {
        _modelDir = dir;
        _error = null;
      });
    }
  }

  Future<void> _startRecording() async {
    final bool hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (mounted) setState(() => _error = '需要麦克风权限');
      return;
    }
    final Directory tempDir = await getTemporaryDirectory();
    final String path = '${tempDir.path}${Platform.pathSeparator}record_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav),
      path: path,
    );
    if (mounted) setState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    final String? path = await _recorder.stop();
    if (mounted) {
      setState(() {
        _isRecording = false;
        if (path != null) {
          _audioPath = path;
          _error = null;
        }
      });
    }
  }

  Future<void> _transcribe() async {
    if (_engine.needsLocalModel && _modelDir == null) {
      setState(() => _error = '请先选择模型目录');
      return;
    }
    if (_audioPath == null) {
      setState(() => _error = '请先选择或录制音频');
      return;
    }
    final File audioFile = File(_audioPath!);
    if (!audioFile.existsSync()) {
      setState(() => _error = '音频文件不存在');
      return;
    }
    setState(() {
      _isTranscribing = true;
      _error = null;
      _result = null;
    });
    try {
      final TranscriptionResult result = _engine is SenseVoiceEngine
          ? await _transcribeInIsolate()
          : await _engine.transcribe(_audioPath!, modelSource: _modelDir);
      if (mounted) {
        setState(() {
          _isTranscribing = false;
          _result = result;
        });
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('Transcribe error: $e\n$st');
      }
      if (mounted) {
        setState(() {
          _isTranscribing = false;
          _error = e.toString();
        });
      }
    }
  }

  /// 在 isolate 中执行转写（当前仅 SenseVoice 需 isolate，避免阻塞 UI）。
  Future<TranscriptionResult> _transcribeInIsolate() async {
    return compute(
      (p) => transcribeSenseVoiceInIsolate(p.$1, p.$2),
      (_modelDir!, _audioPath!),
    );
  }

  /// 开始实时转写：按片长录音 → 转写 → 追加结果，循环直到停止。
  Future<void> _startRealtimeTranscribe() async {
    if (_modelDir == null) {
      setState(() => _error = '模型未加载，请等待 assets 加载完成');
      return;
    }
    final bool hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (mounted) setState(() => _error = '需要麦克风权限');
      return;
    }
    if (!mounted) return;
    setState(() {
      _isRealtimeTranscribing = true;
      _error = null;
    });
    _runRealtimeLoop();
  }

  void _stopRealtimeTranscribe() {
    setState(() => _isRealtimeTranscribing = false);
    if (_isRecording) _recorder.stop();
  }

  /// 录音与转写重叠：每段录完立即开始下一段，当前段在后台转写，不阻塞录音与 UI。
  Future<void> _runRealtimeLoop() async {
    const Duration chunkDuration = Duration(seconds: 3);
    while (mounted && _isRealtimeTranscribing) {
      final Directory tempDir = await getTemporaryDirectory();
      final String path = '${tempDir.path}${Platform.pathSeparator}realtime_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.wav),
        path: path,
      );
      if (!mounted || !_isRealtimeTranscribing) break;
      setState(() => _isRecording = true);

      await Future.delayed(chunkDuration);
      if (!mounted || !_isRealtimeTranscribing) break;

      final String? stoppedPath = await _recorder.stop();
      if (mounted) setState(() => _isRecording = false);
      if (!mounted || !_isRealtimeTranscribing) break;

      if (stoppedPath != null && File(stoppedPath).existsSync() && _modelDir != null) {
        final String pathToTranscribe = stoppedPath;
        final String modelDir = _modelDir!;
        compute(
          (p) => transcribeSenseVoiceInIsolate(p.$1, p.$2),
          (modelDir, pathToTranscribe),
        ).then((TranscriptionResult result) {
          if (!mounted || !_isRealtimeTranscribing) return;
          if (result.text.isNotEmpty) {
            setState(() => _realtimeText = _realtimeText + result.text);
          }
        }).catchError((Object e) {
          if (kDebugMode) debugPrint('Realtime chunk error: $e');
        });
      }
      // 不 await 转写，直接进入下一轮录音，实现「边说边录、后台出字」
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool needModel = _engine.needsLocalModel;
    final bool canTranscribe = (!needModel || _modelDir != null) && _audioPath != null;

    return Scaffold(
      appBar: AppBar(
        title: Text('byvo · ${_engine.displayName}'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('模型（${_engine.displayName}）', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            needModel
                ? (_modelDir != null ? '模型：已从 assets 加载' : '模型：未加载')
                : '当前引擎无需本地模型',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          const Text('音频', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            _audioPath != null
                ? '已选: ${_audioPath!.length > 50 ? '...${_audioPath!.substring(_audioPath!.length - 50)}' : _audioPath}'
                : '录制后点击转写',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _isTranscribing || _isRealtimeTranscribing
                    ? null
                    : _isRecording
                        ? _stopRecording
                        : _startRecording,
                icon: Icon(_isRealtimeTranscribing ? Icons.mic : (_isRecording ? Icons.stop : Icons.mic)),
                label: Text(_isRealtimeTranscribing ? '录制' : (_isRecording ? '停止录制' : '录制')),
              ),
              FilledButton.icon(
                onPressed: _isRealtimeTranscribing
                    ? _stopRealtimeTranscribe
                    : (_isTranscribing || _modelDir == null || _isRecording ? null : _startRealtimeTranscribe),
                icon: _isRealtimeTranscribing ? const Icon(Icons.stop_circle) : const Icon(Icons.record_voice_over),
                label: Text(_isRealtimeTranscribing ? '停止实时转写' : '实时转写'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: (_isTranscribing || _isRealtimeTranscribing || !canTranscribe) ? null : _transcribe,
            icon: _isTranscribing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.transcribe),
            label: Text(_isTranscribing ? '转写中…' : '转写'),
          ),
          if (_realtimeText.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Text('实时转写结果', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SelectableText(_realtimeText),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (_result != null) ...[
            const SizedBox(height: 24),
            const Text('转写结果', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SelectableText(_result!.text),
            if (_result!.emotion != null || _result!.event != null) ...[
              const SizedBox(height: 12),
              const Text('情感 / 环境', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                '情感: ${_result!.emotion ?? "—"}  环境: ${_result!.event ?? "—"}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_result!.lang != null) ...[
              const SizedBox(height: 4),
              Text('语种: ${_result!.lang}', style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ],
      ),
    );
  }
}
