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
const String _keyOverlayLastX = 'overlay_last_x';
const String _keyOverlayLastY = 'overlay_last_y';

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

class _TranscriptionMvpPageState extends State<TranscriptionMvpPage>
    with WidgetsBindingObserver {
  static const BackendTranscriptionEngine _engine = BackendTranscriptionEngine();

  String? _audioPath;
  bool _isTranscribing = false;
  TranscriptionResult? _result;
  String? _error;
  bool _isRecording = false;
  bool _isRealtimeTranscribing = false;
  bool _realtimeConnectionClosed = false;
  String _realtimeText = '';
  final AudioRecorder _recorder = AudioRecorder();
  RealtimeStreamEngine? _realtimeStreamEngine;
  StreamSubscription<String>? _realtimeTextSub;
  StreamSubscription<void>? _realtimeClosedSub;

  bool _showFloatingBall = false;
  bool _effectTranscribe = false;
  int _idleTimeoutSec = 30;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadShowFloatingBall();
    _loadEffectTranscribe();
    _loadIdleTimeoutSec();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_showFloatingBall || !Platform.isAndroid) return;
    Future<void>.microtask(() async {
      try {
        if (!mounted) return;
        if (await FlutterOverlayWindow.isActive()) return;
        await _doShowGlobalOverlay();
      } catch (_) {}
    });
  }

  Future<void> _loadEffectTranscribe() async {
    final value = await loadEffectTranscribe();
    if (mounted) setState(() => _effectTranscribe = value);
  }

  Future<void> _loadIdleTimeoutSec() async {
    final value = await loadIdleTimeoutSec();
    if (mounted) setState(() => _idleTimeoutSec = value);
  }

  Future<void> _loadShowFloatingBall() async {
    final prefs = await SharedPreferences.getInstance();
    final show = prefs.getBool(_keyShowFloatingBall) ?? false;
    if (!mounted) return;
    setState(() => _showFloatingBall = show);
    if (show && Platform.isAndroid) {
      try {
        if (!await FlutterOverlayWindow.isActive()) await _doShowGlobalOverlay();
      } catch (_) {}
    }
  }

  /// 仅全局悬浮窗（Android）。插件原生侧把宽高当像素用，56 会变成很小方块，故用 180。
  /// 若有上次保存的位置则用 startPosition 恢复，否则按 alignment 放到默认位置。
  Future<void> _doShowGlobalOverlay() async {
    OverlayPosition? startPosition;
    final prefs = await SharedPreferences.getInstance();
    final x = prefs.getDouble(_keyOverlayLastX);
    final y = prefs.getDouble(_keyOverlayLastY);
    if (x != null && y != null) {
      startPosition = OverlayPosition(x, y);
    }
    await FlutterOverlayWindow.showOverlay(
      height: 180,
      width: 180,
      alignment: OverlayAlignment.centerRight,
      enableDrag: true,
      overlayTitle: 'byvo',
      overlayContent: '长按转写',
      startPosition: startPosition,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      _realtimeConnectionClosed = false;
      _realtimeText = '';
      _error = null;
    });
    final engine = RealtimeStreamEngine();
    _realtimeStreamEngine = engine;
    try {
      await engine.start(effect: _effectTranscribe, idleTimeoutSec: _idleTimeoutSec);
      if (!mounted || !_isRealtimeTranscribing) return;
      _safeSetState(() => _isRecording = true);
      _realtimeTextSub = engine.textStream.listen((String text) {
        if (!mounted || !_isRealtimeTranscribing) return;
        _safeSetState(() => _realtimeText = text);
      }, onError: (Object e) {
        if (kDebugMode) debugPrint('Realtime stream error: $e');
        _safeSetState(() => _error = e.toString());
      });
      _realtimeClosedSub = engine.connectionClosedStream.listen((_) {
        if (!mounted) return;
        _realtimeTextSub?.cancel();
        _realtimeTextSub = null;
        _realtimeStreamEngine?.stop();
        _realtimeStreamEngine = null;
        _safeSetState(() {
          _isRealtimeTranscribing = false;
          _isRecording = false;
          _realtimeConnectionClosed = true;
        });
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
    await _realtimeClosedSub?.cancel();
    _realtimeClosedSub = null;
    await _realtimeTextSub?.cancel();
    await _realtimeStreamEngine?.stop();
    _realtimeStreamEngine = null;
    _realtimeTextSub = null;
    _safeSetState(() {
      _isRealtimeTranscribing = false;
      _isRecording = false;
      _realtimeConnectionClosed = true;
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
        // 先尝试直接显示悬浮窗；能显示则说明已有权限（避免 isPermissionGranted 从后台恢复后误报未授权）
        try {
          await _doShowGlobalOverlay();
          if (!mounted) return;
          setState(() => _showFloatingBall = true);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_keyShowFloatingBall, true);
          return;
        } on PlatformException catch (e) {
          if (e.code != 'PERMISSION') rethrow;
          // 无权限，弹出系统「显示在其他应用上层」设置页
          final granted = await FlutterOverlayWindow.requestPermission();
          if (!mounted) return;
          if (granted == true) {
            await _doShowGlobalOverlay();
            if (!mounted) return;
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
          return;
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
    // 关闭前保存当前位置，下次打开时恢复
    try {
      final pos = await FlutterOverlayWindow.getOverlayPosition();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_keyOverlayLastX, pos.x);
      await prefs.setDouble(_keyOverlayLastY, pos.y);
    } catch (_) {}
    // 先更新 UI 和偏好，再关闭 overlay，保证开关一定能关上（即使 overlay 已消失或 closeOverlay 异常）
    setState(() => _showFloatingBall = false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowFloatingBall, false);
    try {
      await FlutterOverlayWindow.closeOverlay();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final bool canTranscribe = _audioPath != null;

    return Scaffold(
      appBar: AppBar(
        title: Text('byvo · ${_engine.displayName}'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              height: kToolbarHeight + MediaQuery.of(context).padding.top,
              padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 8, 16, 8),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.inversePrimary.withOpacity(0.3)),
              alignment: Alignment.centerLeft,
              child: const Text('设置', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              title: const Text('悬浮球'),
              trailing: Switch(
                value: _showFloatingBall,
                onChanged: (bool v) => _onFloatingBallSwitchChanged(context, v),
              ),
            ),
            ListTile(
              title: const Text('LLM处理'),
              trailing: Switch(
                value: _effectTranscribe,
                onChanged: (bool v) async {
                  setState(() => _effectTranscribe = v);
                  await saveEffectTranscribe(v);
                },
              ),
            ),
            ListTile(
              title: const Text('无文本断开(秒)'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove),
                    onPressed: _idleTimeoutSec <= 0
                        ? null
                        : () async {
                            final v = (_idleTimeoutSec - 1).clamp(0, 300);
                            setState(() => _idleTimeoutSec = v);
                            await saveIdleTimeoutSec(v);
                          },
                  ),
                  SizedBox(
                    width: 36,
                    child: Text('$_idleTimeoutSec', textAlign: TextAlign.center),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: _idleTimeoutSec >= 300
                        ? null
                        : () async {
                            final v = (_idleTimeoutSec + 1).clamp(0, 300);
                            setState(() => _idleTimeoutSec = v);
                            await saveIdleTimeoutSec(v);
                          },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
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
                      if (_realtimeText.isNotEmpty || _realtimeConnectionClosed) ...[
                        const SizedBox(height: 24),
                        const Text('实时转写结果', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        if (_realtimeText.isNotEmpty) SelectableText(_realtimeText),
                        if (_realtimeConnectionClosed) ...[
                          if (_realtimeText.isNotEmpty) const SizedBox(height: 8),
                          Text('已关闭', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
                        ],
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
  StreamSubscription<void>? _closedSub;
  Timer? _drainTimer;
  bool _isActive = false;

  @override
  void dispose() {
    _drainTimer?.cancel();
    _closedSub?.cancel();
    _textSub?.cancel();
    _engine?.stop();
    super.dispose();
  }

  Future<void> _startRealtime() async {
    if (!await _recorder.hasPermission()) return;
    setState(() => _isActive = true);
    final effect = await loadEffectTranscribe();
    final idleSec = await loadIdleTimeoutSec();
    final engine = RealtimeStreamEngine();
    _engine = engine;
    try {
      await engine.start(effect: effect, idleTimeoutSec: idleSec);
      if (!mounted || !_isActive) return;
      _textSub = engine.textStream.listen((_) {});
      _closedSub = engine.connectionClosedStream.listen((_) {
        if (!mounted || _engine != engine) return;
        _stopRealtime();
      });
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
    await _closedSub?.cancel();
    _closedSub = null;
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
      elevation: 0,
      shadowColor: Colors.transparent,
      child: GestureDetector(
        onLongPressStart: (_) => _startRealtime(),
        onLongPressEnd: (_) => _scheduleDrain(),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest.shortestSide > 0
                ? constraints.biggest.shortestSide
                : 72.0;
            return Center(
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _isActive ? Icons.stop : Icons.mic,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  size: size * 0.5,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
