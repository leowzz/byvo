import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talker_flutter/talker_flutter.dart';

import 'app_talker.dart';
import 'config/backend_config.dart';
import 'scan/setup_qr_page.dart';
import 'scan/setup_qr_parser.dart';
import 'transcription/backend_engine.dart';
import 'transcription/realtime_stream_engine.dart';
import 'transcription/transcription_result.dart';

const String _keyShowFloatingBall = 'show_floating_ball';
const String _keyOverlayLastX = 'overlay_last_x';
const String _keyOverlayLastY = 'overlay_last_y';
const Color _warmCanvas = Color(0xFFF6F5F4);
const Color _warmSurface = Color(0xFFFFFFFF);
const Color _warmBorder = Color(0x1A000000);
const Color _warmText = Color(0xF2000000);
const Color _warmMuted = Color(0xFF615D59);
const Color _accentBlue = Color(0xFF0075DE);

/// 悬浮窗通过 shareData 发送此前缀 + 正文，主应用解析后调用平台填入当前输入框。
const String _insertTextPrefix = 'INSERT_TEXT:\n';
final MethodChannel _insertTextChannel = MethodChannel('byvo/insert_text');

void main() {
  logInfo('Talker logging ready');
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'byvo',
      theme: ThemeData(
        scaffoldBackgroundColor: _warmCanvas,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _accentBlue,
          brightness: Brightness.light,
          surface: _warmSurface,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: _warmCanvas,
          foregroundColor: _warmText,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: _warmText,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: _warmSurface,
          indicatorColor: const Color(0x14213183),
          surfaceTintColor: Colors.transparent,
          labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>(
            (states) => TextStyle(
              fontSize: 12,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
              color: _warmText,
            ),
          ),
        ),
        cardTheme: const CardThemeData(
          color: _warmSurface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
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
  static const BackendTranscriptionEngine _engine =
      BackendTranscriptionEngine();
  late final TextEditingController _urlController;
  late final TextEditingController _apiKeyController;

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

  bool _showFloatingBall = false;
  bool _effectTranscribe = false;
  int _idleTimeoutSec = 30;
  int _tabIndex = 0;

  /// 主页面测试输入框，用于测悬浮球转写填入。
  final TextEditingController _testInputController = TextEditingController();

  /// 长按录音按钮按下时间，用于松手后判断是否达到最短时长再转写。
  DateTime? _holdRecordStartTime;
  static const Duration _holdRecordMinDuration = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    _apiKeyController = TextEditingController();
    WidgetsBinding.instance.addObserver(this);
    _loadShowFloatingBall();
    _loadEffectTranscribe();
    _loadIdleTimeoutSec();
    _loadBackendFields();
    _overlayLogSub = FlutterOverlayWindow.overlayListener.listen((dynamic msg) {
      final s = msg?.toString() ?? '';
      if (s.startsWith(_insertTextPrefix)) {
        final text = s.substring(_insertTextPrefix.length);
        _requestInsertTextToFocusedField(text);
        logDebug('已请求填入当前输入框');
        return;
      }
      logDebug(s);
    });
  }

  Future<void> _loadBackendFields() async {
    final url = await loadBackendUrl();
    final apiKey = await loadBackendApiKey();
    if (!mounted) return;
    _urlController.text = url;
    _apiKeyController.text = apiKey;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed ||
        !_showFloatingBall ||
        !Platform.isAndroid) {
      return;
    }
    Future<void>.microtask(() async {
      try {
        if (!mounted) return;
        if (await FlutterOverlayWindow.isActive()) {
          return;
        }
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
        if (!await FlutterOverlayWindow.isActive()) {
          await _doShowGlobalOverlay();
        }
      } catch (_) {}
    }
  }

  /// 仅全局悬浮窗（Android）。插件原生侧把宽高当像素用，56 会变成很小方块，故用 180。
  /// enableDrag: true 时由原生处理拖动；长按录音依赖 Flutter 收到触摸，若被原生占用则仅在未拖动时生效。
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
      overlayContent: '长按约 0.5 秒录音',
      startPosition: startPosition,
    );
  }

  /// 请求将文本填入当前聚焦的输入框（需已开启 byvo 辅助功能）。
  void _requestInsertTextToFocusedField(String text) {
    if (!Platform.isAndroid) return;
    unawaited(
      _insertTextChannel.invokeMethod<bool>('insertTextToFocusedField',
          {'text': text}).catchError((Object e, StackTrace st) {
        logError(e, st, '填入输入框失败');
        return null;
      }),
    );
  }

  @override
  void dispose() {
    _overlayLogSub?.cancel();
    _testInputController.dispose();
    _urlController.dispose();
    _apiKeyController.dispose();
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
    final String path =
        '${tempDir.path}${Platform.pathSeparator}record_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav),
      path: path,
    );
    _safeSetState(() => _isRecording = true);
    logDebug('[按钮] 录制=开始');
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
    logDebug('[按钮] 录制=停止 path=${path != null}');
    if (path != null && mounted) {
      await _transcribe();
    }
  }

  /// 长按录音松手：停止录音，若时长达到 [_holdRecordMinDuration] 则上传并调用转写接口。
  Future<void> _stopHoldAndTranscribe(BuildContext? context) async {
    if (!_isRecording || _holdRecordStartTime == null) return;
    final DateTime startTime = _holdRecordStartTime!;
    _holdRecordStartTime = null;
    final String? path = await _recorder.stop();
    _safeSetState(() => _isRecording = false);
    logDebug('[按钮] 长按录音=松手 path=${path != null}');
    if (path == null) return;
    final Duration duration = DateTime.now().difference(startTime);
    if (duration < _holdRecordMinDuration) {
      logDebug('[按钮] 长按录音=太短 ${duration.inMilliseconds}ms');
      _safeSetState(() =>
          _error = '录音太短，请按住至少 ${_holdRecordMinDuration.inMilliseconds}ms');
      return;
    }
    _safeSetState(() {
      _audioPath = path;
      _error = null;
    });
    if (mounted) {
      await _transcribe();
    }
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
    logDebug('[按钮] 转写=开始');
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
      logDebug('[按钮] 转写=完成');
    } catch (e, st) {
      logError(e, st, 'Transcribe error');
      _safeSetState(() {
        _isTranscribing = false;
        _error = e.toString();
      });
      logDebug('[按钮] 转写=失败');
      if (mounted) {
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
    logDebug('[按钮] 实时转写=开始');
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
      logDebug('[按钮] 实时转写=已连接(录制中)');
      _realtimeTextSub = engine.textStream.listen((String text) {
        if (!mounted || !_isRealtimeTranscribing) return;
        _safeSetState(() => _realtimeText = text);
      }, onError: (Object e) {
        logError(e, null, 'Realtime stream error');
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
        logDebug('[按钮] 实时转写=连接已关闭');
      });
    } catch (e, st) {
      logError(e, st, 'Realtime stream start error');
      _safeSetState(() => _error = e.toString());
      setState(() {
        _isRealtimeTranscribing = false;
        _isRecording = false;
      });
      logDebug('[按钮] 实时转写=启动失败');
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
    logDebug('[按钮] 实时转写=已停止');
  }

  Future<void> _saveBackendSettings(BuildContext context) async {
    await saveBackendUrl(_urlController.text.trim());
    await saveBackendApiKey(_apiKeyController.text.trim());
    if (_isRealtimeTranscribing) {
      await _stopRealtimeTranscribe();
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存')),
      );
    }
  }

  Future<void> _scanAndFillSettings(BuildContext context) async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const SetupQrPage(),
      ),
    );
    if (!context.mounted || raw == null) return;

    try {
      final config = parseByvoSetupUri(raw);
      setState(() {
        _urlController.text = config.baseUrl;
        _apiKeyController.text = config.apiKey;
      });
    } on FormatException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message.toString())),
      );
    }
  }

  Future<void> _onFloatingBallSwitchChanged(
      BuildContext context, bool value) async {
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
    final pageTitles = <String>['首页', '设置'];

    return Scaffold(
      appBar: AppBar(
        title: Text(pageTitles[_tabIndex]),
        actions: [
          if (kDebugMode && _tabIndex == 0)
            IconButton(
              tooltip: '调试日志',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => TalkerScreen(talker: appTalker),
                  ),
                );
              },
              icon: const Icon(Icons.bug_report_outlined),
            ),
        ],
      ),
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _buildHomeTab(context, canTranscribe),
          _buildSettingsTab(context),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) => setState(() => _tabIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }

  Widget _buildHomeTab(BuildContext context, bool canTranscribe) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '临时测试',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: _warmText,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 6),
              Text(
                '用于验证后端连接、填入能力和悬浮球状态，保持操作简短直接。',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: _warmMuted,
                    ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _StatusPill(
                    label:
                        _urlController.text.trim().isEmpty ? '后端未配置' : '后端已配置',
                    active: _urlController.text.trim().isNotEmpty,
                  ),
                  _StatusPill(
                    label: _showFloatingBall ? '悬浮球已开启' : '悬浮球已关闭',
                    active: _showFloatingBall,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle(
                title: '悬浮球',
                subtitle: Platform.isAndroid ? '首页直接开关，便于临时测试' : '仅 Android 支持',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _showFloatingBall ? '当前处于开启状态' : '当前处于关闭状态',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: _warmText,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  Switch(
                    value: _showFloatingBall,
                    onChanged: (bool v) =>
                        _onFloatingBallSwitchChanged(context, v),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle(
                title: '测试填入',
                subtitle: '点一下输入框获得焦点，再通过悬浮球或录音结果验证填入',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _testInputController,
                decoration: _fieldDecoration(
                  '点一下获得焦点，再用悬浮球长按录音转写',
                ),
                maxLines: 3,
                minLines: 1,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle(
                title: '音频测试',
                subtitle: _audioPath != null
                    ? '已选: ${_audioPath!.length > 42 ? '...${_audioPath!.substring(_audioPath!.length - 42)}' : _audioPath}'
                    : '录制后可立即测试转写',
              ),
              const SizedBox(height: 12),
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
                          : (_isRecording && _holdRecordStartTime == null
                              ? Icons.stop
                              : Icons.mic),
                    ),
                    label: Text(
                      _isRealtimeTranscribing
                          ? '录制'
                          : (_isRecording && _holdRecordStartTime == null
                              ? '停止录制'
                              : '录制'),
                    ),
                  ),
                  GestureDetector(
                    onPanDown: (_) {
                      if (_isTranscribing ||
                          _isRealtimeTranscribing ||
                          _isRecording) {
                        return;
                      }
                      _holdRecordStartTime = DateTime.now();
                      logDebug('[按钮] 长按录音=按下');
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
                                ? Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest
                                : const Color(0xFFF2F9FF),
                          ),
                          child: Icon(
                            _holdRecordStartTime != null
                                ? Icons.stop
                                : Icons.mic_none,
                            color: _holdRecordStartTime != null
                                ? Theme.of(context).colorScheme.onSurfaceVariant
                                : _accentBlue,
                            size: 28,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '长按录音转写',
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: _warmMuted,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _isRealtimeTranscribing
                        ? _stopRealtimeTranscribe
                        : (_isTranscribing || _isRecording
                            ? null
                            : () => _startRealtimeTranscribe(context)),
                    icon: _isRealtimeTranscribing
                        ? const Icon(Icons.stop_circle)
                        : const Icon(Icons.record_voice_over),
                    label: Text(
                      _isRealtimeTranscribing ? '停止实时转写' : '实时转写',
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: (_isTranscribing ||
                            _isRealtimeTranscribing ||
                            !canTranscribe)
                        ? null
                        : _transcribe,
                    icon: _isTranscribing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.transcribe),
                    label: Text(_isTranscribing ? '转写中…' : '转写'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_realtimeText.isNotEmpty || _realtimeConnectionClosed) ...[
          const SizedBox(height: 16),
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionTitle(title: '实时转写结果'),
                const SizedBox(height: 12),
                if (_realtimeText.isNotEmpty) SelectableText(_realtimeText),
                if (_realtimeConnectionClosed) ...[
                  if (_realtimeText.isNotEmpty) const SizedBox(height: 8),
                  Text(
                    '已关闭',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: _warmMuted),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          _SectionCard(
            child: Text(
              _error!,
              style: const TextStyle(color: Color(0xFFB42318)),
            ),
          ),
        ],
        if (_result != null) ...[
          const SizedBox(height: 16),
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionTitle(title: '转写结果'),
                const SizedBox(height: 12),
                SelectableText(_result!.text),
                if (_result!.emotion != null || _result!.event != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    '情感: ${_result!.emotion ?? "—"}  环境: ${_result!.event ?? "—"}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _warmMuted,
                        ),
                  ),
                ],
                if (_result!.lang != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '语种: ${_result!.lang}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _warmMuted,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSettingsTab(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                title: '连接',
                subtitle: '调整后端地址、API Key，或通过二维码快速填充',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _urlController,
                decoration: _fieldDecoration('http://192.168.x.x:8000'),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKeyController,
                decoration: _fieldDecoration('输入服务端要求的 X-API-Key'),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _scanAndFillSettings(context),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('扫码填充'),
                  ),
                  FilledButton(
                    onPressed: () => _saveBackendSettings(context),
                    child: const Text('保存连接配置'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                title: '转写',
                subtitle: '控制效果处理与无文本自动断开行为',
              ),
              const SizedBox(height: 8),
              _SettingRow(
                title: 'LLM处理',
                subtitle: '开启后做去口语化与语义顺滑',
                trailing: Switch(
                  value: _effectTranscribe,
                  onChanged: (bool v) async {
                    setState(() => _effectTranscribe = v);
                    await saveEffectTranscribe(v);
                  },
                ),
              ),
              const Divider(height: 20, color: _warmBorder),
              _SettingRow(
                title: '无文本断开(秒)',
                subtitle: '实时转写在长时间无结果时自动关闭连接',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: _idleTimeoutSec <= 0
                          ? null
                          : () async {
                              final v = (_idleTimeoutSec - 1).clamp(0, 300);
                              setState(() => _idleTimeoutSec = v);
                              await saveIdleTimeoutSec(v);
                            },
                      icon: const Icon(Icons.remove),
                    ),
                    SizedBox(
                      width: 32,
                      child: Text(
                        '$_idleTimeoutSec',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: _warmText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _idleTimeoutSec >= 300
                          ? null
                          : () async {
                              final v = (_idleTimeoutSec + 1).clamp(0, 300);
                              setState(() => _idleTimeoutSec = v);
                              await saveIdleTimeoutSec(v);
                            },
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle(
                title: '悬浮球',
                subtitle: '主要开关放在首页，这里保留说明，便于理解当前用途',
              ),
              SizedBox(height: 8),
              Text(
                '首页用于临时测试和快速控制悬浮球；设置页集中放置连接与转写参数。',
                style: TextStyle(color: _warmMuted, height: 1.5),
              ),
            ],
          ),
        ),
        if (kDebugMode) ...[
          const SizedBox(height: 16),
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionTitle(
                  title: '调试',
                  subtitle: '开发环境下可查看 Talker 日志',
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('打开调试日志'),
                  subtitle: const Text('查看网络与客户端交互日志'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TalkerScreen(talker: appTalker),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  InputDecoration _fieldDecoration(String hintText) {
    return InputDecoration(
      hintText: hintText,
      filled: true,
      fillColor: _warmSurface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _warmBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _accentBlue),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _warmSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _warmBorder),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: _warmText,
                fontWeight: FontWeight.w700,
              ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _warmMuted,
                  height: 1.5,
                ),
          ),
        ],
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: active ? const Color(0xFFF2F9FF) : const Color(0xFFF1EFED),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? _accentBlue : _warmMuted,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    this.subtitle,
    required this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: _warmText,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _warmMuted,
                        height: 1.45,
                      ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        trailing,
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
/// 不调用 resizeOverlay（插件会把 180 当 dp 转成像素，球会突然变大）。拖动由原生 enableDrag 处理。
class OverlayBallPage extends StatefulWidget {
  const OverlayBallPage({super.key});

  @override
  State<OverlayBallPage> createState() => _OverlayBallPageState();
}

class _OverlayBallPageState extends State<OverlayBallPage> {
  final AudioRecorder _recorder = AudioRecorder();
  static const BackendTranscriptionEngine _engine =
      BackendTranscriptionEngine();
  static const Duration _holdRecordMinDuration = Duration(milliseconds: 500);
  DateTime? _holdRecordStartTime;

  void _log(String msg) {
    if (!kDebugMode) return;
    logDebug(msg);
    FlutterOverlayWindow.shareData(msg);
  }

  /// 长文分块发送，避免跨 isolate 消息过长。
  void _logLong(String prefix, String text) {
    if (!kDebugMode) return;
    logDebug('$prefix$text');
    const int chunkSize = 800;
    if (text.length <= chunkSize) {
      FlutterOverlayWindow.shareData('$prefix$text');
      return;
    }
    FlutterOverlayWindow.shareData('$prefix(共${text.length}字)');
    for (int i = 0; i < text.length; i += chunkSize) {
      final String chunk =
          text.substring(i, (i + chunkSize).clamp(0, text.length));
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
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.wav),
          path: path);
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
      final result =
          await _engine.transcribe(path, effect: effect, useLlm: effect);
      _log('[悬浮球] 转写=完成');
      _logLong('[悬浮球] 转写结果: ', result.text);
      FlutterOverlayWindow.shareData('$_insertTextPrefix${result.text}');
      if (Platform.isAndroid && result.text.isNotEmpty) {
        _log('[悬浮球] 请求填入当前输入框');
        try {
          final ok = await _insertTextChannel.invokeMethod<bool>(
            'insertTextToFocusedField',
            <String, dynamic>{'text': result.text},
          );
          _log('[悬浮球] 填入输入框=${ok == true ? "已请求" : "未成功"}');
        } catch (e) {
          _log('[悬浮球] 填入输入框失败: $e');
        }
      }
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
