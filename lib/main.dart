import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/backend_config.dart';
import 'debug_log.dart';
import 'transcription/backend_engine.dart';
import 'transcription/realtime_stream_engine.dart';
import 'transcription/transcription_result.dart';

const String _keyShowFloatingBall = 'show_floating_ball';

void main() {
  if (kDebugMode) {
    // 将 debugPrint 同时输出到调试小窗
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.isNotEmpty) {
        DebugLog.instance.log(message);
      }
      // 保留默认控制台输出
      // ignore: avoid_print
      print(message);
    };
    DebugLog.instance.log('调试日志已就绪');
  }
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
  static const BackendTranscriptionEngine _engine = BackendTranscriptionEngine();

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

  bool _showFloatingBall = false;
  bool _effectTranscribe = false;

  @override
  void initState() {
    super.initState();
    _loadShowFloatingBall();
    _loadEffectTranscribe();
  }

  Future<void> _loadEffectTranscribe() async {
    final value = await loadEffectTranscribe();
    if (mounted) setState(() => _effectTranscribe = value);
  }

  Future<void> _loadShowFloatingBall() async {
    final prefs = await SharedPreferences.getInstance();
    final show = prefs.getBool(_keyShowFloatingBall) ?? false;
    if (!mounted) return;
    setState(() => _showFloatingBall = show);
    if (show && Platform.isAndroid) {
      try {
        if (await FlutterOverlayWindow.isPermissionGranted()) {
          await _doShowGlobalOverlay();
        }
      } catch (_) {}
    }
  }

  /// 仅全局悬浮窗（Android）。
  Future<void> _doShowGlobalOverlay() async {
    await FlutterOverlayWindow.showOverlay(
      height: 56,
      width: 56,
      alignment: OverlayAlignment.centerRight,
      enableDrag: true,
      overlayTitle: 'byvo',
      overlayContent: '长按转写',
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _safeSetState(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  /// 弹窗显示错误信息（后端连不上等）。
  void _showErrorDialog(BuildContext context, String title, String message) {
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: SelectableText(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 检查麦克风权限，未授权时设置 _error 并返回 false。
  Future<bool> _requireMicPermission() async {
    final bool ok = await _recorder.hasPermission();
    if (!ok) _safeSetState(() => _error = '需要麦克风权限');
    return ok;
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

  Future<void> _stopRecording(BuildContext context) async {
    final String? path = await _recorder.stop();
    _safeSetState(() {
      _isRecording = false;
      if (path != null) {
        _audioPath = path;
        _error = null;
      }
    });
    if (path != null) _transcribe(context);
  }

  Future<void> _transcribe(BuildContext? context) async {
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
      final TranscriptionResult result = await _engine.transcribe(
        _audioPath!,
        effect: _effectTranscribe,
      );
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
      if (context != null && context.mounted) {
        _showErrorDialog(context, '转写失败', e.toString());
      }
    }
  }

  /// 豆包流式转写：WebSocket 边录边出字。
  Future<void> _startRealtimeTranscribe(BuildContext context) async {
    if (!await _requireMicPermission()) return;
    setState(() {
      _isRealtimeTranscribing = true;
      _realtimeText = '';
      _error = null;
    });
    final engine = RealtimeStreamEngine();
    _realtimeStreamEngine = engine;
    try {
      await engine.start(effect: _effectTranscribe);
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
      if (context.mounted) {
        _showErrorDialog(context, '实时转写连接失败', e.toString());
      }
    }
  }

  Future<void> _stopRealtimeTranscribe() async {
    await _realtimeTextSub?.cancel();
    await _realtimeStreamEngine?.stop();
    _realtimeStreamEngine = null;
    _realtimeTextSub = null;
    _safeSetState(() {
      _isRealtimeTranscribing = false;
      _isRecording = false;
    });
  }

  Future<void> _openBackendSettings(BuildContext context) async {
    final bool? didSave = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => _BackendSettingsDialog(),
    );
    if (didSave == true && _isRealtimeTranscribing) {
      await _stopRealtimeTranscribe();
    }
  }

  Future<void> _onFloatingBallSwitchChanged(BuildContext context, bool value) async {
    if (value) {
      if (!Platform.isAndroid) {
        if (mounted && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('全局悬浮球仅支持 Android')),
          );
        }
        return;
      }
      try {
        // 主动弹出系统权限申请（显示在其他应用上层）
        final granted = await FlutterOverlayWindow.requestPermission();
        if (!mounted) return;
        if (granted == true) {
          await _doShowGlobalOverlay();
          setState(() => _showFloatingBall = true);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_keyShowFloatingBall, true);
        } else {
          setState(() => _showFloatingBall = false);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('需要允许「显示在其他应用上层」才能使用全局悬浮球')),
            );
          }
        }
      } on MissingPluginException {
        setState(() => _showFloatingBall = false);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('当前环境不支持全局悬浮球')),
          );
        }
      } catch (_) {
        setState(() => _showFloatingBall = false);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('开启悬浮球失败')),
          );
        }
      }
      return;
    }
    try {
      await FlutterOverlayWindow.closeOverlay();
    } catch (_) {}
    setState(() => _showFloatingBall = false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowFloatingBall, false);
  }

  @override
  Widget build(BuildContext context) {
    final bool canTranscribe = _audioPath != null;

    return Scaffold(
      appBar: AppBar(
        title: Text('byvo · ${_engine.displayName}'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          // 上部约 70%：主内容
          Expanded(
            flex: 7,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                OutlinedButton.icon(
                  onPressed: () => _openBackendSettings(context),
                  icon: const Icon(Icons.settings),
                  label: const Text('后端地址配置'),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('悬浮球', style: TextStyle(fontWeight: FontWeight.bold)),
                    Switch(
                      value: _showFloatingBall,
                      onChanged: (bool v) => _onFloatingBallSwitchChanged(context, v),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('效果转写（去口语化）', style: TextStyle(fontWeight: FontWeight.bold)),
                    Switch(
                      value: _effectTranscribe,
                      onChanged: (bool v) async {
                        setState(() => _effectTranscribe = v);
                        await saveEffectTranscribe(v);
                      },
                    ),
                  ],
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
                              ? () => _stopRecording(context)
                              : _startRecording,
                      icon: Icon(_isRealtimeTranscribing ? Icons.mic : (_isRecording ? Icons.stop : Icons.mic)),
                      label: Text(_isRealtimeTranscribing ? '录制' : (_isRecording ? '停止录制' : '录制')),
                    ),
                    FilledButton.icon(
                      onPressed: _isRealtimeTranscribing
                          ? _stopRealtimeTranscribe
                          : (_isTranscribing || _isRecording ? null : () => _startRealtimeTranscribe(context)),
                      icon: _isRealtimeTranscribing ? const Icon(Icons.stop_circle) : const Icon(Icons.record_voice_over),
                      label: Text(_isRealtimeTranscribing ? '停止实时转写' : '实时转写'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: (_isTranscribing || _isRealtimeTranscribing || !canTranscribe) ? null : () => _transcribe(context),
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
          ),
          // 底部约 30%：调试日志小窗
          Expanded(
            flex: 3,
            child: _DebugLogPanel(),
          ),
        ],
      ),
    );
  }
}

/// 底部调试日志面板，流式展示 [DebugLog] 输出。
class _DebugLogPanel extends StatefulWidget {
  @override
  State<_DebugLogPanel> createState() => _DebugLogPanelState();
}

class _DebugLogPanelState extends State<_DebugLogPanel> {
  final ScrollController _scrollController = ScrollController();
  List<String> _lines = [];
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _lines = List<String>.from(DebugLog.instance.lines);
    _sub = DebugLog.instance.stream.listen((String line) {
      if (!mounted) return;
      setState(() => _lines.insert(0, line));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.6),
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.bug_report, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text('调试日志', style: theme.textTheme.titleSmall),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    DebugLog.instance.clear();
                    setState(() => _lines.clear());
                  },
                  child: const Text('清空'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              itemCount: _lines.length,
              itemBuilder: (BuildContext context, int index) {
                return SelectableText(
                  _lines[index],
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                );
              },
            ),
          ),
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
                hintText: 'http://192.168.177.20:8000 (Android 模拟器)',
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
            if (context.mounted) Navigator.of(context).pop(true);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

// ========== 全局悬浮窗（Android 独立 overlay isolate） ==========

/// 全局悬浮窗入口，由 flutter_overlay_window 在独立 isolate 中调用。
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      useMaterial3: true,
    ),
    home: const OverlayBallPage(),
  ));
}

/// 全局悬浮窗内的球：长按开始实时转写，松手后等发送完毕再关闭。
class OverlayBallPage extends StatefulWidget {
  const OverlayBallPage({super.key});

  @override
  State<OverlayBallPage> createState() => _OverlayBallPageState();
}

class _OverlayBallPageState extends State<OverlayBallPage> {
  final AudioRecorder _recorder = AudioRecorder();
  RealtimeStreamEngine? _engine;
  StreamSubscription<String>? _textSub;
  Timer? _drainTimer;
  bool _isActive = false;

  @override
  void dispose() {
    _drainTimer?.cancel();
    _textSub?.cancel();
    _engine?.stop();
    super.dispose();
  }

  Future<void> _startRealtime() async {
    if (!await _recorder.hasPermission()) return;
    setState(() => _isActive = true);
    final effect = await loadEffectTranscribe();
    final engine = RealtimeStreamEngine();
    _engine = engine;
    try {
      await engine.start(effect: effect);
      if (!mounted || !_isActive) return;
      _textSub = engine.textStream.listen((_) {});
    } catch (e) {
      if (mounted) setState(() => _isActive = false);
    }
  }

  void _scheduleDrain() {
    _drainTimer?.cancel();
    _drainTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || _engine == null) {
        _drainTimer?.cancel();
        return;
      }
      if (_engine!.isDrainComplete) {
        _drainTimer?.cancel();
        _stopRealtime();
      }
    });
  }

  Future<void> _stopRealtime() async {
    await _textSub?.cancel();
    await _engine?.stop();
    _engine = null;
    _textSub = null;
    if (mounted) setState(() => _isActive = false);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onLongPressStart: (_) => _startRealtime(),
        onLongPressEnd: (_) => _scheduleDrain(),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            _isActive ? Icons.stop : Icons.mic,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
            size: 28,
          ),
        ),
      ),
    );
  }
}
