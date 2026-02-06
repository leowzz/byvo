import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/backend_config.dart';
import 'transcription/backend_engine.dart';
import 'transcription/realtime_stream_engine.dart';
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

const String _prefEngineIndex = 'engine_index';

class _TranscriptionMvpPageState extends State<TranscriptionMvpPage> {
  int _engineIndex = 0;
  TranscriptionEngine get _engine => _engineIndex == 0
      ? BackendTranscriptionEngine(engine: 'sensevoice')
      : BackendTranscriptionEngine(engine: 'volcengine');

  String? _audioPath;
  bool _isTranscribing = false;
  TranscriptionResult? _result;
  String? _error;
  bool _isRecording = false;
  bool _isRealtimeTranscribing = false;
  String _realtimeText = '';
  final AudioRecorder _recorder = AudioRecorder();
  RealtimeStreamEngine? _realtimeStreamEngine;
  StreamSubscription<String>? _realtimeTextSub;

  void _safeSetState(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  /// 检查麦克风权限，未授权时设置 _error 并返回 false。
  Future<bool> _requireMicPermission() async {
    final bool ok = await _recorder.hasPermission();
    if (!ok) _safeSetState(() => _error = '需要麦克风权限');
    return ok;
  }

  @override
  void initState() {
    super.initState();
    _loadEnginePreference();
  }

  Future<void> _loadEnginePreference() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? saved = prefs.getInt(_prefEngineIndex);
    final int index = (saved != null && saved >= 0 && saved <= 1) ? saved : 0;
    _safeSetState(() => _engineIndex = index);
  }

  Future<void> _setEngineIndex(int index) async {
    if (index == _engineIndex) return;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefEngineIndex, index);
    _safeSetState(() => _engineIndex = index);
  }

  Future<void> _startRecording() async {
    if (!await _requireMicPermission()) return;
    final Directory tempDir = await getTemporaryDirectory();
    final String path = '${tempDir.path}${Platform.pathSeparator}record_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav),
      path: path,
    );
    _safeSetState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    final String? path = await _recorder.stop();
    _safeSetState(() {
      _isRecording = false;
      if (path != null) {
        _audioPath = path;
        _error = null;
      }
    });
    if (path != null) _transcribe();
  }

  Future<void> _transcribe() async {
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
      final TranscriptionResult result = await _engine.transcribe(_audioPath!);
      _safeSetState(() {
        _isTranscribing = false;
        _result = result;
      });
    } catch (e, st) {
      if (kDebugMode) debugPrint('Transcribe error: $e\n$st');
      _safeSetState(() {
        _isTranscribing = false;
        _error = e.toString();
      });
    }
  }

  /// 开始实时转写：豆包用流式 WS，SenseVoice 用分块 HTTP。
  Future<void> _startRealtimeTranscribe() async {
    if (!await _requireMicPermission()) return;
    setState(() {
      _isRealtimeTranscribing = true;
      _realtimeText = '';
      _error = null;
    });
    if (_engineIndex == 1) {
      _runRealtimeStream();
    } else {
      _runRealtimeLoop();
    }
  }

  /// 豆包流式转写：record.startStream + WebSocket，无分块间隙。
  Future<void> _runRealtimeStream() async {
    final engine = RealtimeStreamEngine();
    _realtimeStreamEngine = engine;
    try {
      await engine.start();
      if (!mounted || !_isRealtimeTranscribing) return;
      _safeSetState(() => _isRecording = true);

      _realtimeTextSub = engine.textStream.listen((String text) {
        if (!mounted || !_isRealtimeTranscribing) return;
        _safeSetState(() => _realtimeText = text);
      }, onError: (Object e) {
        if (kDebugMode) debugPrint('Realtime stream error: $e');
        _safeSetState(() => _error = e.toString());
      });
    } catch (e, st) {
      if (kDebugMode) debugPrint('Realtime stream start error: $e\n$st');
      _safeSetState(() => _error = e.toString());
      setState(() {
        _isRealtimeTranscribing = false;
        _isRecording = false;
      });
    }
  }

  /// 停止实时转写：只关实时转写与录音器，不进入「录制」流程，不写 _audioPath。
  Future<void> _stopRealtimeTranscribe() async {
    if (_realtimeStreamEngine != null) {
      await _realtimeTextSub?.cancel();
      await _realtimeStreamEngine!.stop();
      _realtimeStreamEngine = null;
      _realtimeTextSub = null;
    } else {
      _recorder.stop();
    }
    _safeSetState(() {
      _isRealtimeTranscribing = false;
      _isRecording = false;
    });
  }

  Future<void> _openBackendSettings(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => _BackendSettingsDialog(),
    );
  }

  /// 录音与转写重叠：每段录完立即开始下一段，当前段在后台转写，不阻塞录音与 UI。
  /// 在 stop() 后立刻 start(下一段)，避免两段之间的间隙丢字。
  Future<void> _runRealtimeLoop() async {
    const Duration chunkDuration = Duration(seconds: 3);
    final Directory tempDir = await getTemporaryDirectory();
    String pathCurrent =
        '${tempDir.path}${Platform.pathSeparator}realtime_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav),
      path: pathCurrent,
    );
    if (!mounted || !_isRealtimeTranscribing) return;
    _safeSetState(() => _isRecording = true);

    while (mounted && _isRealtimeTranscribing) {
      await Future.delayed(chunkDuration);
      if (!mounted || !_isRealtimeTranscribing) break;

      final String? stoppedPath = await _recorder.stop();
      if (!mounted || !_isRealtimeTranscribing) break;
      final String pathNext =
          '${tempDir.path}${Platform.pathSeparator}realtime_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.wav),
        path: pathNext,
      );
      _safeSetState(() => _isRecording = true);
      if (!mounted || !_isRealtimeTranscribing) break;

      if (stoppedPath != null && File(stoppedPath).existsSync()) {
        void appendResult(TranscriptionResult result) {
          if (!mounted || !_isRealtimeTranscribing) return;
          if (result.text.isNotEmpty) _safeSetState(() => _realtimeText = _realtimeText + result.text);
        }
        _engine
            .transcribe(stoppedPath)
            .then(appendResult)
            .catchError((Object e) {
          if (kDebugMode) debugPrint('Realtime chunk error: $e');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool canTranscribe = _audioPath != null;

    return Scaffold(
      appBar: AppBar(
        title: Text('byvo · ${_engine.displayName}'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('引擎', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('SenseVoice (后端)'), icon: Icon(Icons.phone_android)),
              ButtonSegment(value: 1, label: Text('豆包 (后端)'), icon: Icon(Icons.cloud)),
            ],
            selected: {_engineIndex},
            onSelectionChanged: (Set<int> s) {
              final int v = s.single;
              _setEngineIndex(v);
            },
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _openBackendSettings(context),
            icon: const Icon(Icons.settings),
            label: const Text('后端地址配置'),
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
                    : (_isTranscribing || _isRecording ? null : _startRealtimeTranscribe),
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

class _BackendSettingsDialog extends StatefulWidget {
  const _BackendSettingsDialog();

  @override
  State<_BackendSettingsDialog> createState() => _BackendSettingsDialogState();
}

class _BackendSettingsDialogState extends State<_BackendSettingsDialog> {
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    loadBackendUrl().then((String url) {
      if (mounted) _urlController.text = url;
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('后端地址配置'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: '后端 Base URL',
                hintText: 'http://10.0.2.2:8000 (Android 模拟器)',
              ),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () async {
            await saveBackendUrl(_urlController.text.trim());
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
