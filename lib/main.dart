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
  StreamSubscription<dynamic>? _overlayLogSub;
  String? _overlayLogFilePath;
  Timer? _overlayLogPollTimer;

  bool _showFloatingBall = false;
  bool _effectTranscribe = false;
  int _idleTimeoutSec = 30;

  /// 长按录音按钮按下时间，用于松手后判断是否达到最短时长再转写。
  DateTime? _holdRecordStartTime;
  static const Duration _holdRecordMinDuration = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadShowFloatingBall();
    _loadEffectTranscribe();
    _loadIdleTimeoutSec();
    _overlayLogSub = FlutterOverlayWindow.overlayListener.listen((dynamic msg) {
      DebugLog.instance.log(msg?.toString() ?? '');
    });
    _initOverlayLogPathAndPoll();
  }

  Future<void> _initOverlayLogPathAndPoll() async {
    String? path = (await SharedPreferences.getInstance()).getString(kOverlayDebugLogPathKey);
    if (path == null || path.isEmpty) {
      final Directory d = await getTemporaryDirectory();
      path = '${d.path}${Platform.pathSeparator}$kOverlayDebugLogFileName';
      await (await SharedPreferences.getInstance()).setString(kOverlayDebugLogPathKey, path);
    }
    if (!mounted) return;
    _overlayLogFilePath = path;
    _overlayLogPollTimer = Timer.periodic(const Duration(milliseconds: 800), (_) => _pollOverlayLog());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _pollOverlayLog();
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
  /// enableDrag: false 时触摸才能传到 Flutter，长按录音才可用；球不能拖动，需在应用内关掉再开可重定位。
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
      enableDrag: false,
      overlayTitle: 'byvo',
      overlayContent: '长按约 0.5 秒录音',
      startPosition: startPosition,
    );
  }

  void _pollOverlayLog() {
    final path = _overlayLogFilePath;
    if (path == null) return;
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final String content = f.readAsStringSync();
      if (content.isEmpty) return;
      f.writeAsStringSync('');
      final lines = content.split('\n');
      for (final line in lines) {
        final s = line.trim();
        if (s.isNotEmpty) DebugLog.instance.log(s);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _overlayLogPollTimer?.cancel();
    _overlayLogSub?.cancel();
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
    if (kDebugMode) debugPrint('[按钮] 录制=开始');
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
    if (kDebugMode) debugPrint('[按钮] 录制=停止 path=${path != null}');
    if (path != null) _transcribe(context);
  }

  /// 长按录音松手：停止录音，若时长达到 [_holdRecordMinDuration] 则上传并调用转写接口。
  Future<void> _stopHoldAndTranscribe(BuildContext? context) async {
    if (!_isRecording || _holdRecordStartTime == null) return;
    final DateTime startTime = _holdRecordStartTime!;
    _holdRecordStartTime = null;
    final String? path = await _recorder.stop();
    _safeSetState(() => _isRecording = false);
    if (kDebugMode) debugPrint('[按钮] 长按录音=松手 path=${path != null}');
    if (path == null) return;
    final Duration duration = DateTime.now().difference(startTime);
    if (duration < _holdRecordMinDuration) {
      if (kDebugMode) debugPrint('[按钮] 长按录音=太短 ${duration.inMilliseconds}ms');
      _safeSetState(() => _error = '录音太短，请按住至少 ${_holdRecordMinDuration.inMilliseconds}ms');
      return;
    }
    _safeSetState(() {
      _audioPath = path;
      _error = null;
    });
    await _transcribe(context);
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
    if (kDebugMode) debugPrint('[按钮] 转写=开始');
    try {
      final TranscriptionResult result = await _engine.transcribe(
        _audioPath!,
        effect: _effectTranscribe,
        useLlm: _effectTranscribe,
      );
      _safeSetState(() {
        _isTranscribing = false;
        _result = result;
      });
      if (kDebugMode) debugPrint('[按钮] 转写=完成');
    } catch (e, st) {
      if (kDebugMode) debugPrint('Transcribe error: $e\n$st');
      _safeSetState(() {
        _isTranscribing = false;
        _error = e.toString();
      });
      if (kDebugMode) debugPrint('[按钮] 转写=失败');
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
    if (kDebugMode) debugPrint('[按钮] 实时转写=开始');
    final engine = RealtimeStreamEngine();
    _realtimeStreamEngine = engine;
    try {
      await engine.start(
        effect: _effectTranscribe,
        useLlm: _effectTranscribe,
        idleTimeoutSec: _idleTimeoutSec,
      );
      if (!mounted || !_isRealtimeTranscribing) return;
      _safeSetState(() => _isRecording = true);
      if (kDebugMode) debugPrint('[按钮] 实时转写=已连接(录制中)');
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
        if (kDebugMode) debugPrint('[按钮] 实时转写=连接已关闭');
      });
    } catch (e, st) {
      if (kDebugMode) debugPrint('Realtime stream start error: $e\n$st');
      _safeSetState(() => _error = e.toString());
      setState(() {
        _isRealtimeTranscribing = false;
        _isRecording = false;
      });
      if (kDebugMode) debugPrint('[按钮] 实时转写=启动失败');
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
    if (kDebugMode) debugPrint('[按钮] 实时转写=已停止');
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
                                : (_holdRecordStartTime != null
                                    ? null
                                    : _isRecording
                                        ? () => _stopRecording(context)
                                        : _startRecording),
                            icon: Icon(
                              _isRealtimeTranscribing
                                  ? Icons.mic
                                  : (_isRecording && _holdRecordStartTime == null ? Icons.stop : Icons.mic),
                            ),
                            label: Text(
                              _isRealtimeTranscribing
                                  ? '录制'
                                  : (_isRecording && _holdRecordStartTime == null ? '停止录制' : '录制'),
                            ),
                          ),
                          GestureDetector(
                            onPanDown: (_) {
                              if (_isTranscribing || _isRealtimeTranscribing || _isRecording) return;
                              _holdRecordStartTime = DateTime.now();
                              if (kDebugMode) debugPrint('[按钮] 长按录音=按下');
                              _startRecording();
                            },
                            onPanEnd: (_) => _stopHoldAndTranscribe(context),
                            onPanCancel: () => _stopHoldAndTranscribe(context),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  width: 56,
                                  height: 56,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _holdRecordStartTime != null
                                        ? Theme.of(context).colorScheme.surfaceContainerHighest
                                        : Theme.of(context).colorScheme.primaryContainer,
                                  ),
                                  child: Icon(
                                    _holdRecordStartTime != null ? Icons.stop : Icons.mic_none,
                                    color: _holdRecordStartTime != null
                                        ? Theme.of(context).colorScheme.onSurfaceVariant
                                        : Theme.of(context).colorScheme.onPrimaryContainer,
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '长按录音转写',
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ],
                            ),
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

/// 全局悬浮窗内的球：与主页面「长按录音转写」一致，长按录音、松手停止并调用 POST 转写接口。
/// 不调用 resizeOverlay（插件会把 180 当 dp 转成像素，球会突然变大）。拖拽仍由原生 enableDrag 处理。
class OverlayBallPage extends StatefulWidget {
  const OverlayBallPage({super.key});

  @override
  State<OverlayBallPage> createState() => _OverlayBallPageState();
}

class _OverlayBallPageState extends State<OverlayBallPage> {
  final AudioRecorder _recorder = AudioRecorder();
  static const BackendTranscriptionEngine _engine = BackendTranscriptionEngine();
  static const Duration _holdRecordMinDuration = Duration(milliseconds: 500);
  DateTime? _holdRecordStartTime;
  String? _overlayLogFilePath;
  Future<void>? _overlayLogPathReady;

  Future<void> _ensureOverlayLogPath() async {
    if (_overlayLogFilePath != null) return;
    _overlayLogPathReady ??= _loadOverlayLogPath();
    await _overlayLogPathReady;
  }

  Future<void> _loadOverlayLogPath() async {
    final prefs = await SharedPreferences.getInstance();
    String? path = prefs.getString(kOverlayDebugLogPathKey);
    if (path == null || path.isEmpty) {
      final Directory d = await getTemporaryDirectory();
      path = '${d.path}${Platform.pathSeparator}$kOverlayDebugLogFileName';
      await prefs.setString(kOverlayDebugLogPathKey, path);
    }
    if (mounted) _overlayLogFilePath = path;
  }

  void _log(String msg) {
    if (!kDebugMode) return;
    debugPrint(msg);
    FlutterOverlayWindow.shareData(msg);
    unawaited(_ensureOverlayLogPath().then((_) {
      final path = _overlayLogFilePath;
      if (path != null) {
        try {
          File(path).writeAsStringSync('$msg\n', mode: FileMode.append);
        } catch (_) {}
      }
    }));
  }

  /// 长文分块发送；同时写文件供主应用轮询（先确保路径再写）。
  void _logLong(String prefix, String text) {
    if (!kDebugMode) return;
    debugPrint('$prefix$text');
    unawaited(_ensureOverlayLogPath().then((_) {
      final path = _overlayLogFilePath;
      if (path != null) {
        try {
          File(path).writeAsStringSync('$prefix$text\n', mode: FileMode.append);
        } catch (_) {}
      }
    }));
    const int chunkSize = 800;
    if (text.length <= chunkSize) {
      FlutterOverlayWindow.shareData('$prefix$text');
      return;
    }
    FlutterOverlayWindow.shareData('$prefix(共${text.length}字)');
    for (int i = 0; i < text.length; i += chunkSize) {
      final String chunk = text.substring(i, (i + chunkSize).clamp(0, text.length));
      FlutterOverlayWindow.shareData(chunk);
    }
  }

  /// 悬浮球在独立引擎中运行，record 的 hasPermission() 在 overlay 上下文中常误报无权限（主应用已授权即可录）。
  /// 直接尝试 start，失败再视为无权限。
  Future<void> _startHoldRecord() async {
    try {
      final Directory tempDir = await getTemporaryDirectory();
      final String path =
          '${tempDir.path}${Platform.pathSeparator}overlay_record_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.wav), path: path);
      if (mounted) {
        setState(() => _holdRecordStartTime = DateTime.now());
        _log('[悬浮球] 录制=开始');
      }
    } catch (e) {
      final String msg = e.toString().toLowerCase();
      if (msg.contains('permission') || msg.contains('权限')) {
        _log('[悬浮球] 录制=无权限');
      } else {
        _log('[悬浮球] 录制=启动失败 $e');
      }
    }
  }

  Future<void> _stopHoldAndTranscribe() async {
    if (_holdRecordStartTime == null) return;
    _log('[悬浮球] 长按=松手');
    final DateTime startTime = _holdRecordStartTime!;
    _holdRecordStartTime = null;
    final String? path = await _recorder.stop();
    if (mounted) setState(() {});
    if (path == null) {
      _log('[悬浮球] 松手=无路径');
      return;
    }
    final Duration duration = DateTime.now().difference(startTime);
    if (duration < _holdRecordMinDuration) {
      _log('[悬浮球] 松手=太短 ${duration.inMilliseconds}ms');
      return;
    }
    try {
      _log('[悬浮球] 转写=开始');
      final effect = await loadEffectTranscribe();
      final result = await _engine.transcribe(path, effect: effect, useLlm: effect);
      _log('[悬浮球] 转写=完成');
      _logLong('[悬浮球] 转写结果: ', result.text);
    } catch (e) {
      _log('[悬浮球] 转写=失败 $e');
    }
    try {
      await File(path).delete();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final bool isRecording = _holdRecordStartTime != null;
    return Material(
      color: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      child: GestureDetector(
        onLongPressStart: (_) {
          if (_holdRecordStartTime == null) {
            _log('[悬浮球] 长按=按下');
            _startHoldRecord();
          }
        },
        onLongPressEnd: (_) => _stopHoldAndTranscribe(),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest.shortestSide > 0
                ? constraints.biggest.shortestSide
                : 72.0;
            return Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isRecording
                      ? Theme.of(context).colorScheme.surfaceContainerHighest
                      : Theme.of(context).colorScheme.primaryContainer,
                ),
                child: Icon(
                  isRecording ? Icons.stop : Icons.mic_none,
                  color: isRecording
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.onPrimaryContainer,
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
