import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'sensevoice_model_loader.dart';
import 'sensevoice_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'byvo SenseVoice MVP',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const SenseVoiceMvpPage(),
    );
  }
}

class SenseVoiceMvpPage extends StatefulWidget {
  const SenseVoiceMvpPage({super.key});

  @override
  State<SenseVoiceMvpPage> createState() => _SenseVoiceMvpPageState();
}

class _SenseVoiceMvpPageState extends State<SenseVoiceMvpPage> {
  String? _modelDir;
  String? _audioPath;
  bool _isTranscribing = false;
  OfflineRecognizerResult? _result;
  String? _error;
  bool _isRecording = false;
  final AudioRecorder _recorder = AudioRecorder();

  @override
  void initState() {
    super.initState();
    _loadModelFromAssets();
  }

  Future<void> _loadModelFromAssets() async {
    final String? dir = await ensureSenseVoiceModelFromAssets();
    if (dir != null && mounted) {
      setState(() {
        _modelDir = dir;
        _error = null;
      });
    }
  }

  /// 选择 model.int8.onnx 文件，模型目录取其所在目录。
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
    if (_modelDir == null || _audioPath == null) {
      setState(() => _error = '请先选择模型目录和音频');
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
      final OfflineRecognizerResult result = await compute(
        (p) => transcribeWithSenseVoice(p.$1, p.$2),
        (_modelDir!, _audioPath!),
      );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('byvo SenseVoice MVP'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('模型（SenseVoice Small 阿里）', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            _modelDir != null
                ? '已选目录: ${_modelDir!.length > 50 ? '...${_modelDir!.substring(_modelDir!.length - 50)}' : _modelDir}'
                : '未选择（将 model.int8.onnx 与 tokens.txt 放入 assets/sensevoice/ 或点击下方选择）',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _pickModelDir,
                icon: const Icon(Icons.folder_open),
                label: const Text('选择模型目录（选 model.int8.onnx）'),
              ),
              if (_modelDir == null)
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
          Row(
            children: [
              FilledButton.icon(
                onPressed: _isTranscribing ? null : _pickWavFile,
                icon: const Icon(Icons.audiotrack),
                label: const Text('选择 WAV'),
              ),
              const SizedBox(width: 8),
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
            onPressed: (_isTranscribing || _modelDir == null || _audioPath == null)
                ? null
                : _transcribe,
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
            if (_result!.emotion.isNotEmpty || _result!.event.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('情感 / 环境', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                '情感: ${_result!.emotion.isEmpty ? "—" : _result!.emotion}  环境: ${_result!.event.isEmpty ? "—" : _result!.event}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_result!.lang.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('语种: ${_result!.lang}', style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ],
      ),
    );
  }
}
