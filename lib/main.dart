import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/volcengine_config.dart';
import 'sensevoice_model_loader.dart';
import 'transcription/sensevoice_engine.dart';
import 'transcription/transcription_engine.dart';
import 'transcription/transcription_result.dart';
import 'transcription/volcengine_engine.dart';

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
  TranscriptionEngine get _engine =>
      _engineIndex == 0 ? SenseVoiceEngine() : VolcengineEngine();

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
    _loadEnginePreference();
  }

  Future<void> _loadEnginePreference() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? saved = prefs.getInt(_prefEngineIndex);
    final int index = (saved != null && saved >= 0 && saved <= 1) ? saved : 0;
    if (mounted) setState(() => _engineIndex = index);
    if (index == 0) _loadModelFromAssets();
  }

  Future<void> _setEngineIndex(int index) async {
    if (index == _engineIndex) return;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefEngineIndex, index);
    if (mounted) {
      setState(() => _engineIndex = index);
      if (index == 0) _loadModelFromAssets();
    }
  }

  Future<void> _loadModelFromAssets() async {
    if (_engineIndex != 0) return;
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
      if (path != null &&
          (_engineIndex != 0 || _modelDir != null)) {
        _transcribe();
      }
    }
  }

  Future<void> _transcribe() async {
    if (_engine.needsLocalModel && _modelDir == null) {
      setState(() => _error = '请先等待模型加载');
      return;
    }
    if (_engineIndex == 1) {
      final VolcengineCredentials cred = await loadVolcengineCredentials();
      if (!cred.isValid) {
        setState(() => _error = '请在设置中配置豆包 API 密钥');
        return;
      }
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

  /// 开始实时转写：按片长录音 → 转写 → 追加结果，循环直到停止。支持本地 SenseVoice 与远程豆包 API。
  Future<void> _startRealtimeTranscribe() async {
    if (_engineIndex == 0 && _modelDir == null) {
      setState(() => _error = '请等待本地模型加载完成');
      return;
    }
    if (_engineIndex == 1) {
      final VolcengineCredentials cred = await loadVolcengineCredentials();
      if (!cred.isValid) {
        if (mounted) setState(() => _error = '请在设置中配置豆包 API 密钥');
        return;
      }
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

  /// 停止实时转写：只关实时转写与录音器，不进入「录制」流程，不写 _audioPath。
  void _stopRealtimeTranscribe() {
    setState(() {
      _isRealtimeTranscribing = false;
      _isRecording = false;
    });
    _recorder.stop();
  }

  Future<void> _openVolcengineSettings(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => _VolcengineSettingsDialog(
        credentialsFuture: loadVolcengineCredentials(),
      ),
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
    setState(() => _isRecording = true);

    while (mounted && _isRealtimeTranscribing) {
      await Future.delayed(chunkDuration);
      if (!mounted || !_isRealtimeTranscribing) break;

      final String? stoppedPath = await _recorder.stop();
      if (!mounted || !_isRealtimeTranscribing) break;
      // 立即开始下一段，缩小间隙，减少边界丢字
      final String pathNext =
          '${tempDir.path}${Platform.pathSeparator}realtime_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.wav),
        path: pathNext,
      );
      if (mounted) setState(() => _isRecording = true);
      if (!mounted || !_isRealtimeTranscribing) break;

      if (stoppedPath != null && File(stoppedPath).existsSync()) {
        final String pathToTranscribe = stoppedPath;
        void appendResult(TranscriptionResult result) {
          if (!mounted || !_isRealtimeTranscribing) return;
          if (result.text.isNotEmpty) {
            setState(() => _realtimeText = _realtimeText + result.text);
          }
        }
        if (_engineIndex == 0 && _modelDir != null) {
          final String modelDir = _modelDir!;
          compute(
            (p) => transcribeSenseVoiceInIsolate(p.$1, p.$2),
            (modelDir, pathToTranscribe),
          ).then(appendResult).catchError((Object e) {
            if (kDebugMode) debugPrint('Realtime chunk error: $e');
          });
        } else if (_engineIndex == 1) {
          VolcengineEngine()
              .transcribe(pathToTranscribe, modelSource: null)
              .then(appendResult)
              .catchError((Object e) {
            if (kDebugMode) debugPrint('Realtime chunk error: $e');
          });
        }
      }
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
          const Text('引擎', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('本地 SenseVoice'), icon: Icon(Icons.phone_android)),
              ButtonSegment(value: 1, label: Text('远程豆包 API'), icon: Icon(Icons.cloud)),
            ],
            selected: {_engineIndex},
            onSelectionChanged: (Set<int> s) {
              final int v = s.single;
              _setEngineIndex(v);
            },
          ),
          const SizedBox(height: 8),
          Text(
            needModel
                ? (_modelDir != null ? '模型：已从 assets 加载' : '模型：未加载')
                : '当前引擎无需本地模型',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_engineIndex == 1) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _openVolcengineSettings(context),
              icon: const Icon(Icons.settings),
              label: const Text('豆包 API 配置'),
            ),
          ],
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
                    : (_isTranscribing || _isRecording
                        ? null
                        : ((_engineIndex == 0 && _modelDir != null) || _engineIndex == 1
                            ? _startRealtimeTranscribe
                            : null)),
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

class _VolcengineSettingsDialog extends StatefulWidget {
  const _VolcengineSettingsDialog({required this.credentialsFuture});

  final Future<VolcengineCredentials> credentialsFuture;

  @override
  State<_VolcengineSettingsDialog> createState() => _VolcengineSettingsDialogState();
}

class _VolcengineSettingsDialogState extends State<_VolcengineSettingsDialog> {
  late final TextEditingController _appKey;
  late final TextEditingController _accessKey;
  late final TextEditingController _resourceId;

  @override
  void initState() {
    super.initState();
    _appKey = TextEditingController();
    _accessKey = TextEditingController();
    _resourceId = TextEditingController(text: 'volc.bigasr.sauc.duration');
    widget.credentialsFuture.then((VolcengineCredentials cred) {
      if (!mounted) return;
      if (cred.isValid) {
        _appKey.text = cred.appKey;
        _accessKey.text = cred.accessKey;
        _resourceId.text = cred.resourceId;
      }
    });
  }

  @override
  void dispose() {
    _appKey.dispose();
    _accessKey.dispose();
    _resourceId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('豆包 API 配置'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _appKey,
              decoration: const InputDecoration(
                labelText: 'App Key (X-Api-App-Key)',
                hintText: '火山引擎控制台获取',
              ),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _accessKey,
              decoration: const InputDecoration(
                labelText: 'Access Key (X-Api-Access-Key)',
                hintText: 'Access Token',
              ),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _resourceId,
              decoration: const InputDecoration(
                labelText: 'Resource ID (X-Api-Resource-Id)',
                hintText: 'volc.bigasr.sauc.duration',
              ),
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
            await saveVolcengineCredentials(VolcengineCredentials(
              appKey: _appKey.text.trim(),
              accessKey: _accessKey.text.trim(),
              resourceId: _resourceId.text.trim(),
            ));
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
