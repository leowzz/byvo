import 'dart:io';

import 'package:file_picker/file_picker.dart';
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

  /// 选择模型文件所在目录（当前以 .onnx 选文件，取父目录）。
  Future<void> _pickModelDir() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['onnx'],
    );
    if (result == null || result.files.single.path == null) return;
    final String path = result.files.single.path!;
    final String dir = File(path).parent.path;
    final String tokensPath = '$dir${Platform.pathSeparator}tokens.txt';
    if (!File(tokensPath).existsSync()) {
      if (mounted) setState(() => _error = '该目录下缺少 tokens.txt');
      return;
    }
    if (mounted) {
      setState(() {
        _modelDir = dir;
        _error = null;
      });
    }
  }

  Future<void> _pickWavFile() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowedExtensions: ['wav', 'WAV'],
    );
    if (result == null || result.files.single.path == null) return;
    final String path = result.files.single.path!;
    if (mounted) {
      setState(() {
        _audioPath = path;
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
                ? (_modelDir != null
                    ? '已选目录: ${_modelDir!.length > 50 ? '...${_modelDir!.substring(_modelDir!.length - 50)}' : _modelDir}'
                    : '未选择（将 model.int8.onnx 与 tokens.txt 放入 assets/sensevoice/ 或点击下方选择）')
                : '当前引擎无需本地模型',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (needModel)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _pickModelDir,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择模型目录（选 model.int8.onnx）'),
                ),
                if (_engine is SenseVoiceEngine && _modelDir == null)
                  TextButton(
                    onPressed: _loadModelFromAssets,
                    child: const Text('从 assets 加载'),
                  ),
              ],
            ),
          const SizedBox(height: 24),
          const Text('音频', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            _audioPath != null
                ? '已选: ${_audioPath!.length > 50 ? '...${_audioPath!.substring(_audioPath!.length - 50)}' : _audioPath}'
                : '选择 WAV 或录制',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _isTranscribing ? null : _pickWavFile,
                icon: const Icon(Icons.audiotrack),
                label: const Text('选择 WAV'),
              ),
              FilledButton.icon(
                onPressed: _isTranscribing
                    ? null
                    : _isRecording
                        ? _stopRecording
                        : _startRecording,
                icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                label: Text(_isRecording ? '停止录制' : '录制'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: (_isTranscribing || !canTranscribe) ? null : _transcribe,
            icon: _isTranscribing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.transcribe),
            label: Text(_isTranscribing ? '转写中…' : '转写'),
          ),
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
