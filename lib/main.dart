import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:package_info_plus/package_info_plus.dart';
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
const BackendTranscriptionEngine _sharedBackendEngine =
    BackendTranscriptionEngine();
final Stream<dynamic> _overlayEvents =
    FlutterOverlayWindow.overlayListener.asBroadcastStream();
@visibleForTesting
const ValueKey<String> homeHoldToTranscribeKey =
    ValueKey<String>('home_hold_to_transcribe');
@visibleForTesting
const ValueKey<String> audioTestRealtimeCardKey =
    ValueKey<String>('audio_test_realtime_card');
@visibleForTesting
const ValueKey<String> audioTestTextInsertionCardKey =
    ValueKey<String>('audio_test_text_insertion_card');
@visibleForTesting
const ValueKey<String> audioTestRealtimeToggleButtonKey =
    ValueKey<String>('audio_test_realtime_toggle_button');
bool defaultPlatformIsAndroid() => Platform.isAndroid;

@visibleForTesting
bool Function() debugPlatformIsAndroid = defaultPlatformIsAndroid;
@visibleForTesting
Future<void> Function({
  required String baseUrl,
  required String apiKey,
}) debugVerifyBackendConnection = verifyBackendConnection;

class _RuntimeStatus {
  const _RuntimeStatus({
    required this.title,
    required this.label,
    required this.active,
    required this.icon,
    this.latencyMs,
  });

  final String title;
  final String label;
  final bool active;
  final IconData icon;
  final int? latencyMs;
}

void main() {
  logInfo('Talker logging ready');
  runApp(const MyApp());
}

Future<TranscriptionResult> _transcribeAudioWithCurrentSettings(
  String audioPath,
) async {
  final effect = await loadEffectTranscribe();
  return _sharedBackendEngine.transcribe(
    audioPath,
    effect: effect,
    useLlm: effect,
  );
}

Future<void> _triggerNativeVibration({int durationMs = 12}) async {
  if (!debugPlatformIsAndroid()) {
    await HapticFeedback.vibrate();
    return;
  }
  try {
    await _insertTextChannel.invokeMethod<void>(
      'vibrate',
      <String, dynamic>{'durationMs': durationMs},
    );
  } catch (_) {
    await HapticFeedback.vibrate();
  }
}

abstract class RealtimeTranscriptionAdapter {
  Stream<String> get textStream;
  Stream<void> get connectionClosedStream;
  Future<void> start({
    bool effect = false,
    bool useLlm = false,
    int? idleTimeoutSec,
  });
  Future<void> stop();
  void dispose();
}

class RealtimeStreamEngineAdapter implements RealtimeTranscriptionAdapter {
  RealtimeStreamEngineAdapter({RealtimeStreamEngine? engine})
      : _engine = engine ?? RealtimeStreamEngine();

  final RealtimeStreamEngine _engine;

  @override
  Stream<String> get textStream => _engine.textStream;

  @override
  Stream<void> get connectionClosedStream => _engine.connectionClosedStream;

  @override
  Future<void> start({
    bool effect = false,
    bool useLlm = false,
    int? idleTimeoutSec,
  }) =>
      _engine.start(
        effect: effect,
        useLlm: useLlm,
        idleTimeoutSec: idleTimeoutSec,
      );

  @override
  Future<void> stop() => _engine.stop();

  @override
  void dispose() => _engine.dispose();
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
  const TranscriptionMvpPage({
    super.key,
    this.recorder,
    this.tempDirProvider,
    this.transcribeAudio,
    this.onRecordStartFeedback,
    this.onRecordStopFeedback,
  });

  @visibleForTesting
  final AudioRecorder? recorder;

  @visibleForTesting
  final Future<Directory> Function()? tempDirProvider;

  @visibleForTesting
  final Future<TranscriptionResult> Function(String audioPath)? transcribeAudio;

  @visibleForTesting
  final Future<void> Function()? onRecordStartFeedback;

  @visibleForTesting
  final Future<void> Function()? onRecordStopFeedback;

  @override
  State<TranscriptionMvpPage> createState() => _TranscriptionMvpPageState();
}

class _TranscriptionMvpPageState extends State<TranscriptionMvpPage>
    with WidgetsBindingObserver {
  late final TextEditingController _urlController;
  late final TextEditingController _apiKeyController;

  late final AudioRecorder _recorder;
  StreamSubscription<dynamic>? _overlayLogSub;

  bool _showFloatingBall = false;
  bool _pendingEnableFloatingBallAfterAccessibility = false;
  bool _effectTranscribe = true;
  int _idleTimeoutSec = 30;
  int _tabIndex = 0;
  bool _isSavingConnection = false;
  String _appVersion = '...';
  DateTime? _versionTapAnchor;
  int _versionTapCount = 0;
  _RuntimeStatus _backendStatus = const _RuntimeStatus(
    title: '后端服务',
    label: '检测中',
    active: false,
    icon: Icons.cloud_outlined,
  );
  _RuntimeStatus _micStatus = const _RuntimeStatus(
    title: '录音权限',
    label: '检测中',
    active: false,
    icon: Icons.mic_none_rounded,
  );
  _RuntimeStatus _accessibilityStatus = const _RuntimeStatus(
    title: '无障碍',
    label: '检测中',
    active: false,
    icon: Icons.accessibility_new_rounded,
  );
  _RuntimeStatus _overlayPermissionStatus = const _RuntimeStatus(
    title: '悬浮球权限',
    label: '检测中',
    active: false,
    icon: Icons.bubble_chart_outlined,
  );

  @override
  void initState() {
    super.initState();
    _recorder = widget.recorder ?? AudioRecorder();
    _urlController = TextEditingController();
    _apiKeyController = TextEditingController();
    WidgetsBinding.instance.addObserver(this);
    _loadShowFloatingBall();
    _loadEffectTranscribe();
    _loadIdleTimeoutSec();
    _loadAppInfo();
    _loadBackendFields();
    _overlayLogSub = _overlayEvents.listen((dynamic msg) {
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
    setState(() {
      _urlController.text = url;
      _apiKeyController.text = apiKey;
    });
    await _refreshHomeStatuses();
  }

  Future<void> _loadAppInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _appVersion = '${packageInfo.version} (${packageInfo.buildNumber})';
    });
  }

  Future<void> _refreshHomeStatuses() async {
    final String baseUrl = _urlController.text.trim();
    final String apiKey = _apiKeyController.text.trim();

    _RuntimeStatus backendStatus;
    if (baseUrl.isEmpty) {
      backendStatus = const _RuntimeStatus(
        title: '后端服务',
        label: '未配置',
        active: false,
        icon: Icons.cloud_off_outlined,
      );
    } else if (apiKey.isEmpty) {
      backendStatus = const _RuntimeStatus(
        title: '后端服务',
        label: '缺少 Key',
        active: false,
        icon: Icons.key_off_outlined,
      );
    } else {
      try {
        await debugVerifyBackendConnection(baseUrl: baseUrl, apiKey: apiKey);
        backendStatus = const _RuntimeStatus(
          title: '后端服务',
          label: '已连接',
          active: true,
          icon: Icons.cloud_done_outlined,
        );
      } catch (e) {
        backendStatus = _RuntimeStatus(
          title: '后端服务',
          label: e.toString().replaceFirst('Bad state: ', ''),
          active: false,
          icon: Icons.cloud_off_outlined,
        );
      }
    }

    final bool micGranted = await _recorder.hasPermission(request: false);
    final bool isAndroid = debugPlatformIsAndroid();
    final bool accessibilityEnabled =
        isAndroid ? await _isAccessibilityServiceEnabled() : false;
    bool overlayGranted = false;
    if (isAndroid) {
      try {
        overlayGranted = await FlutterOverlayWindow.isPermissionGranted();
      } catch (_) {
        overlayGranted = false;
      }
    }

    if (!mounted) return;
    setState(() {
      _backendStatus = backendStatus;
      _micStatus = _RuntimeStatus(
        title: '录音权限',
        label: micGranted ? '已允许' : '未允许',
        active: micGranted,
        icon: micGranted ? Icons.mic_rounded : Icons.mic_off_rounded,
      );
      _accessibilityStatus = _RuntimeStatus(
        title: '无障碍',
        label: isAndroid ? (accessibilityEnabled ? '已开启' : '未开启') : '仅 Android',
        active: isAndroid ? accessibilityEnabled : false,
        icon: Icons.accessibility_new_rounded,
      );
      _overlayPermissionStatus = _RuntimeStatus(
        title: '悬浮球权限',
        label: isAndroid ? (overlayGranted ? '已允许' : '未允许') : '仅 Android',
        active: isAndroid ? overlayGranted : false,
        icon: overlayGranted
            ? Icons.bubble_chart_rounded
            : Icons.bubble_chart_outlined,
      );
    });
  }

  void _handleVersionTap() {
    final now = DateTime.now();
    if (_versionTapAnchor == null ||
        now.difference(_versionTapAnchor!) > const Duration(seconds: 2)) {
      _versionTapAnchor = now;
      _versionTapCount = 1;
    } else {
      _versionTapCount += 1;
      _versionTapAnchor = now;
    }
    if (_versionTapCount < 5 || !kDebugMode || !mounted) {
      return;
    }
    _versionTapCount = 0;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TalkerScreen(talker: appTalker),
      ),
    );
  }

  Future<void> _handleBackendStatusTap(BuildContext context) async {
    final String baseUrl = _urlController.text.trim();
    final String apiKey = _apiKeyController.text.trim();
    if (baseUrl.isEmpty || apiKey.isEmpty) {
      if (_tabIndex != 1) {
        setState(() => _tabIndex = 1);
      }
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final startedAt = DateTime.now();
    try {
      await debugVerifyBackendConnection(baseUrl: baseUrl, apiKey: apiKey);
      final latencyMs = DateTime.now().difference(startedAt).inMilliseconds;
      if (!mounted) return;
      setState(() {
        _backendStatus = _RuntimeStatus(
          title: '后端服务',
          label: '已连接',
          active: true,
          icon: Icons.cloud_done_outlined,
          latencyMs: latencyMs,
        );
      });
    } catch (e) {
      if (!context.mounted) return;
      messenger.clearSnackBars();
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
      );
      if (!mounted) return;
      setState(() {
        _backendStatus = _RuntimeStatus(
          title: '后端服务',
          label: e.toString().replaceFirst('Bad state: ', ''),
          active: false,
          icon: Icons.cloud_off_outlined,
        );
      });
    }
  }

  Future<void> _handlePermissionStatusTap(
    BuildContext context,
    _RuntimeStatus status,
  ) async {
    if (status.title == '录音权限') {
      await _recorder.hasPermission();
      await _refreshHomeStatuses();
      return;
    }
    if (status.title == '无障碍') {
      await _insertTextChannel.invokeMethod<void>('openAccessibilitySettings');
      return;
    }
    if (status.title == '悬浮球权限') {
      if (!debugPlatformIsAndroid()) {
        return;
      }
      try {
        await FlutterOverlayWindow.requestPermission();
      } catch (_) {}
      await _refreshHomeStatuses();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !debugPlatformIsAndroid()) {
      return;
    }
    Future<void>.microtask(() async {
      try {
        if (!mounted) return;
        await _refreshHomeStatuses();
        if (_pendingEnableFloatingBallAfterAccessibility) {
          _pendingEnableFloatingBallAfterAccessibility = false;
          final bool accessibilityEnabled =
              await _isAccessibilityServiceEnabled();
          if (!mounted || !accessibilityEnabled) return;
          await _enableFloatingBall(context);
          return;
        }
        if (!_showFloatingBall) return;
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
    if (show && debugPlatformIsAndroid()) {
      try {
        if (!await FlutterOverlayWindow.isActive()) {
          await _doShowGlobalOverlay();
        }
      } catch (_) {}
    }
    await _refreshHomeStatuses();
  }

  Future<void> _persistShowFloatingBall(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowFloatingBall, value);
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
    _urlController.dispose();
    _apiKeyController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _saveBackendSettings(BuildContext context) async {
    final baseUrl = _urlController.text.trim();
    final apiKey = _apiKeyController.text.trim();
    setState(() => _isSavingConnection = true);
    try {
      await debugVerifyBackendConnection(baseUrl: baseUrl, apiKey: apiKey);
      await saveBackendUrl(baseUrl);
      await saveBackendApiKey(apiKey);
      await _refreshHomeStatuses();
      if (context.mounted) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.clearSnackBars();
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(content: Text('连接测试成功，配置已保存')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.clearSnackBars();
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSavingConnection = false);
      }
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
      if (!mounted || !context.mounted) return;
      setState(() {
        _urlController.text = config.baseUrl;
        _apiKeyController.text = config.apiKey;
      });
      await _saveBackendSettings(context);
    } on FormatException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message.toString())),
      );
    }
  }

  Future<bool> _isAccessibilityServiceEnabled() async {
    return await _insertTextChannel.invokeMethod<bool>(
          'isAccessibilityServiceEnabled',
        ) ??
        false;
  }

  Future<void> _enableFloatingBall(BuildContext context) async {
    _pendingEnableFloatingBallAfterAccessibility = false;
    try {
      // 先尝试直接显示悬浮窗；能显示则说明已有权限（避免 isPermissionGranted 从后台恢复后误报未授权）
      try {
        await _doShowGlobalOverlay();
        if (!mounted) return;
        setState(() => _showFloatingBall = true);
        await _persistShowFloatingBall(true);
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
          await _persistShowFloatingBall(true);
        } else {
          setState(() => _showFloatingBall = false);
          await _persistShowFloatingBall(false);
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
      await _persistShowFloatingBall(false);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前环境不支持全局悬浮球')),
        );
      }
    } catch (_) {
      setState(() => _showFloatingBall = false);
      await _persistShowFloatingBall(false);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('开启悬浮球失败')),
        );
      }
    }
  }

  Future<void> _onFloatingBallSwitchChanged(
      BuildContext context, bool value) async {
    if (value) {
      if (!debugPlatformIsAndroid()) {
        if (mounted && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('全局悬浮球仅支持 Android')),
          );
        }
        return;
      }
      setState(() => _showFloatingBall = true);
      await _persistShowFloatingBall(true);
      final bool accessibilityEnabled = await _isAccessibilityServiceEnabled();
      if (!accessibilityEnabled) {
        _pendingEnableFloatingBallAfterAccessibility = true;
        await _insertTextChannel
            .invokeMethod<void>('openAccessibilitySettings');
        return;
      }
      if (!mounted || !context.mounted) return;
      await _enableFloatingBall(context);
      await _refreshHomeStatuses();
      return;
    }
    _pendingEnableFloatingBallAfterAccessibility = false;
    // 关闭前保存当前位置，下次打开时恢复
    try {
      final pos = await FlutterOverlayWindow.getOverlayPosition();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_keyOverlayLastX, pos.x);
      await prefs.setDouble(_keyOverlayLastY, pos.y);
    } catch (_) {}
    // 先更新 UI 和偏好，再关闭 overlay，保证开关一定能关上（即使 overlay 已消失或 closeOverlay 异常）
    setState(() => _showFloatingBall = false);
    await _persistShowFloatingBall(false);
    try {
      await FlutterOverlayWindow.closeOverlay();
    } catch (_) {}
    await _refreshHomeStatuses();
  }

  @override
  Widget build(BuildContext context) {
    final pageTitles = <String>['首页', '设置'];

    return Scaffold(
      appBar: AppBar(
        title: Text(pageTitles[_tabIndex]),
      ),
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _buildHomeTab(context),
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

  Widget _buildHomeTab(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                title: '状态',
                subtitle: '快速查看服务与系统权限是否就绪',
              ),
              const SizedBox(height: 14),
              GridView.count(
                shrinkWrap: true,
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.55,
                children: [
                  _StatusTile(
                    key: const ValueKey<String>('status_backend'),
                    status: _backendStatus,
                    onTap: () => _handleBackendStatusTap(context),
                  ),
                  _StatusTile(
                    key: const ValueKey<String>('status_mic'),
                    status: _micStatus,
                    onTap: () =>
                        _handlePermissionStatusTap(context, _micStatus),
                  ),
                  _StatusTile(
                    key: const ValueKey<String>('status_accessibility'),
                    status: _accessibilityStatus,
                    onTap: () => _handlePermissionStatusTap(
                      context,
                      _accessibilityStatus,
                    ),
                  ),
                  _StatusTile(
                    key: const ValueKey<String>('status_overlay'),
                    status: _overlayPermissionStatus,
                    onTap: () => _handlePermissionStatusTap(
                      context,
                      _overlayPermissionStatus,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _SectionTitle(
                title: '悬浮球',
                subtitle: Platform.isAndroid ? '长按悬浮球即可开始录音转写' : '仅 Android 支持',
              ),
              const SizedBox(height: 12),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _onFloatingBallSwitchChanged(
                    context,
                    !_showFloatingBall,
                  ),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FBFE),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0x220075DE)),
                    ),
                    child: Column(
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 74,
                          height: 74,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _showFloatingBall
                                ? const Color(0xFFEAF4FF)
                                : const Color(0xFFF1EFED),
                          ),
                          child: Icon(
                            _showFloatingBall
                                ? Icons.mic_none
                                : Icons.power_settings_new,
                            size: 34,
                            color: _showFloatingBall ? _accentBlue : _warmMuted,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          _showFloatingBall ? '悬浮球已开启' : '悬浮球已关闭',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: _warmText,
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _showFloatingBall
                              ? '可以切到其他应用中使用'
                              : '开启后可在任意应用中快速发起转写',
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: _warmMuted,
                                    height: 1.5,
                                  ),
                        ),
                        const SizedBox(height: 14),
                        Switch(
                          value: _showFloatingBall,
                          onChanged: (bool v) =>
                              _onFloatingBallSwitchChanged(context, v),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
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
                    onPressed: _isSavingConnection
                        ? null
                        : () => _saveBackendSettings(context),
                    child: Text(_isSavingConnection ? '测试中…' : '保存连接配置'),
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
                title: '工具',
                subtitle: '进入独立测试页验证录音转写与文本填入',
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.graphic_eq_rounded),
                title: const Text('音频测试'),
                subtitle: const Text('长按录音转写，并验证结果展示与填入'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AudioTestPage(
                        recorder: widget.recorder,
                        tempDirProvider: widget.tempDirProvider,
                        transcribeAudio: widget.transcribeAudio,
                        onRecordStartFeedback: widget.onRecordStartFeedback,
                        onRecordStopFeedback: widget.onRecordStopFeedback,
                      ),
                    ),
                  );
                },
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(title: '关于'),
              const SizedBox(height: 12),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _handleVersionTap,
                child: Text(
                  '版本 $_appVersion',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: _warmText,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
        ),
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

class AudioTestPage extends StatefulWidget {
  const AudioTestPage({
    super.key,
    this.recorder,
    this.tempDirProvider,
    this.transcribeAudio,
    this.onRecordStartFeedback,
    this.onRecordStopFeedback,
    this.realtimeAdapterFactory,
  });

  final AudioRecorder? recorder;
  final Future<Directory> Function()? tempDirProvider;
  final Future<TranscriptionResult> Function(String audioPath)? transcribeAudio;
  final Future<void> Function()? onRecordStartFeedback;
  final Future<void> Function()? onRecordStopFeedback;
  final RealtimeTranscriptionAdapter Function()? realtimeAdapterFactory;

  @override
  State<AudioTestPage> createState() => _AudioTestPageState();
}

class _AudioTestPageState extends State<AudioTestPage> {
  late final AudioRecorder _recorder;
  final TextEditingController _testInputController = TextEditingController();
  static const Duration _holdRecordMinDuration = Duration(milliseconds: 500);

  String? _audioPath;
  String? _fileError;
  String? _realtimeError;
  TranscriptionResult? _result;
  bool _isRecording = false;
  bool _isTranscribing = false;
  DateTime? _holdRecordStartTime;
  RealtimeTranscriptionAdapter? _realtimeAdapter;
  StreamSubscription<String>? _realtimeTextSub;
  StreamSubscription<void>? _realtimeClosedSub;
  bool _isRealtimeConnecting = false;
  bool _isRealtimeListening = false;
  String _realtimeStatus = '未开始';
  String _realtimeText = '';

  @override
  void initState() {
    super.initState();
    _recorder = widget.recorder ?? AudioRecorder();
  }

  @override
  void dispose() {
    unawaited(_disposeRealtimeAdapter());
    _testInputController.dispose();
    super.dispose();
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

  Future<bool> _requireMicPermission() async {
    final bool ok = await _recorder.hasPermission();
    if (!ok && mounted) {
      setState(() => _fileError = '需要麦克风权限');
    }
    return ok;
  }

  Future<void> _startRecording() async {
    if (_isRecording || _isTranscribing) return;
    if (!await _requireMicPermission()) return;
    final Directory tempDir =
        await (widget.tempDirProvider?.call() ?? getTemporaryDirectory());
    final String path =
        '${tempDir.path}${Platform.pathSeparator}record_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav),
      path: path,
    );
    if (!mounted) return;
    setState(() {
      _isRecording = true;
      _holdRecordStartTime = DateTime.now();
      _fileError = null;
    });
    await (widget.onRecordStartFeedback?.call() ?? _triggerNativeVibration());
    logDebug('[测试页] 长按录音=开始');
  }

  Future<void> _stopHoldAndTranscribe() async {
    if (!_isRecording || _holdRecordStartTime == null) return;
    final DateTime startTime = _holdRecordStartTime!;
    _holdRecordStartTime = null;
    final String? path = await _recorder.stop();
    await (widget.onRecordStopFeedback?.call() ?? _triggerNativeVibration());
    if (!mounted) return;
    setState(() => _isRecording = false);
    if (path == null) {
      setState(() => _fileError = '未获取到录音文件');
      return;
    }
    final Duration duration = DateTime.now().difference(startTime);
    if (duration < _holdRecordMinDuration) {
      setState(() {
        _audioPath = null;
        _fileError = '录音太短，请按住至少 ${_holdRecordMinDuration.inMilliseconds}ms';
      });
      return;
    }
    setState(() {
      _audioPath = path;
      _fileError = null;
    });
    await _transcribe();
  }

  Future<void> _transcribe() async {
    if (_audioPath == null) {
      setState(() => _fileError = '请先录音');
      return;
    }
    final File audioFile = File(_audioPath!);
    if (!audioFile.existsSync()) {
      setState(() => _fileError = '音频文件不存在');
      return;
    }
    setState(() {
      _isTranscribing = true;
      _fileError = null;
      _result = null;
    });
    try {
      final result = await (widget.transcribeAudio?.call(_audioPath!) ??
          _transcribeAudioWithCurrentSettings(_audioPath!));
      if (!mounted) return;
      setState(() {
        _isTranscribing = false;
        _result = result;
      });
    } catch (e, st) {
      logError(e, st, 'Audio test transcribe error');
      if (!mounted) return;
      setState(() {
        _isTranscribing = false;
        _fileError = e.toString();
      });
    }
  }

  RealtimeTranscriptionAdapter _ensureRealtimeAdapter() {
    return _realtimeAdapter ??= (widget.realtimeAdapterFactory?.call() ??
        RealtimeStreamEngineAdapter());
  }

  Future<void> _disposeRealtimeAdapter() async {
    final adapter = _realtimeAdapter;
    final textSub = _realtimeTextSub;
    final closedSub = _realtimeClosedSub;
    _realtimeTextSub = null;
    _realtimeClosedSub = null;
    _realtimeAdapter = null;
    unawaited(textSub?.cancel() ?? Future<void>.value());
    unawaited(closedSub?.cancel() ?? Future<void>.value());
    try {
      await adapter?.stop();
    } catch (e, st) {
      logError(e, st, 'Audio test realtime stop error');
    }
    adapter?.dispose();
  }

  Future<void> _handleRealtimeStreamError(
      Object error, StackTrace stackTrace) async {
    logError(error, stackTrace, 'Audio test realtime stream error');
    if (mounted) {
      setState(() {
        _isRealtimeConnecting = false;
        _isRealtimeListening = false;
        _realtimeStatus = '连接异常';
        _realtimeError = error.toString();
      });
    }
    await _disposeRealtimeAdapter();
  }

  Future<void> _startRealtimeListening() async {
    if (_isRealtimeListening || _isRealtimeConnecting) return;
    setState(() {
      _isRealtimeConnecting = true;
      _realtimeStatus = '连接中…';
      _realtimeError = null;
    });
    try {
      final effect = await loadEffectTranscribe();
      final idleTimeoutSec = await loadIdleTimeoutSec();
      final adapter = _ensureRealtimeAdapter();
      await _realtimeTextSub?.cancel();
      await _realtimeClosedSub?.cancel();
      _realtimeTextSub = adapter.textStream.listen((text) {
        if (!mounted) return;
        setState(() => _realtimeText = text);
      }, onError: (Object error, StackTrace stackTrace) {
        unawaited(_handleRealtimeStreamError(error, stackTrace));
      });
      _realtimeClosedSub = adapter.connectionClosedStream.listen((_) {
        unawaited(_handleRealtimeAutoDisconnected());
      });
      await adapter.start(
        effect: effect,
        useLlm: effect,
        idleTimeoutSec: idleTimeoutSec,
      );
      if (!mounted) return;
      if (_realtimeAdapter != adapter || !_isRealtimeConnecting) return;
      setState(() {
        _isRealtimeConnecting = false;
        _isRealtimeListening = true;
        _realtimeStatus = '实时监听中';
      });
    } catch (e, st) {
      logError(e, st, 'Audio test realtime start error');
      if (mounted) {
        setState(() {
          _isRealtimeConnecting = false;
          _isRealtimeListening = false;
          _realtimeStatus = '启动失败';
          _realtimeError = e.toString();
        });
      }
      await _disposeRealtimeAdapter();
    }
  }

  Future<void> _stopRealtimeListening({String status = '已停止监听'}) async {
    if (!_isRealtimeListening &&
        !_isRealtimeConnecting &&
        _realtimeAdapter == null) {
      return;
    }
    final textSub = _realtimeTextSub;
    final closedSub = _realtimeClosedSub;
    _realtimeTextSub = null;
    _realtimeClosedSub = null;
    await textSub?.cancel();
    unawaited(closedSub?.cancel() ?? Future<void>.value());
    await _realtimeAdapter?.stop();
    if (!mounted) return;
    setState(() {
      _isRealtimeConnecting = false;
      _isRealtimeListening = false;
      _realtimeStatus = status;
    });
  }

  Future<void> _handleRealtimeAutoDisconnected() async {
    if (!_isRealtimeListening && !_isRealtimeConnecting) return;
    if (mounted) {
      setState(() {
        _isRealtimeConnecting = false;
        _isRealtimeListening = false;
        _realtimeStatus = '已自动断开（长时间无文本）';
      });
    }
    await _disposeRealtimeAdapter();
  }

  Future<void> _toggleRealtimeListening() async {
    if (_isRealtimeListening || _isRealtimeConnecting) {
      await _stopRealtimeListening();
      return;
    }
    await _startRealtimeListening();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('音频测试')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          KeyedSubtree(
            key: audioTestRealtimeCardKey,
            child: _SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionTitle(
                    title: '实时转写',
                    subtitle: '点击开始连续监听，空闲时会自动停止连接',
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: audioTestRealtimeToggleButtonKey,
                    onPressed: _toggleRealtimeListening,
                    icon: Icon(
                      (_isRealtimeListening || _isRealtimeConnecting)
                          ? Icons.stop_circle
                          : Icons.hearing,
                    ),
                    label: Text(
                      _isRealtimeConnecting
                          ? '连接中…'
                          : _isRealtimeListening
                              ? '停止监听'
                              : '开始连续监听',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '状态：$_realtimeStatus',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _warmMuted,
                        ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _realtimeText.isEmpty ? '暂无实时文本' : _realtimeText,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: _warmText,
                        ),
                  ),
                  if (_realtimeError != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _realtimeError!,
                      style: const TextStyle(color: Color(0xFFB42318)),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          KeyedSubtree(
            key: audioTestTextInsertionCardKey,
            child: _SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionTitle(
                    title: '文本填入验证',
                    subtitle: '先点一下输入框获取焦点，再长按下方按钮进行测试',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _testInputController,
                    decoration: _fieldDecoration('点按这里获取焦点'),
                    maxLines: 3,
                    minLines: 1,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionCard(
            child: Column(
              children: [
                const _SectionTitle(
                  title: '长按转写',
                  subtitle: '按住说话，松手后自动上传并展示转写结果',
                ),
                const SizedBox(height: 18),
                GestureDetector(
                  key: homeHoldToTranscribeKey,
                  onPanDown: (_) => _startRecording(),
                  onPanEnd: (_) => _stopHoldAndTranscribe(),
                  onPanCancel: _stopHoldAndTranscribe,
                  child: Column(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isRecording
                              ? Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                              : const Color(0xFFF2F9FF),
                        ),
                        child: Icon(
                          _isRecording ? Icons.stop : Icons.mic_none,
                          color: _isRecording
                              ? Theme.of(context).colorScheme.onSurfaceVariant
                              : _accentBlue,
                          size: 34,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _isRecording ? '松手结束并转写' : '按住开始录音',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: _warmText,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ],
                  ),
                ),
                if (_audioPath != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    '最近录音: ${_audioPath!.split(Platform.pathSeparator).last}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _warmMuted,
                        ),
                  ),
                ],
                if (_isTranscribing) ...[
                  const SizedBox(height: 14),
                  const CircularProgressIndicator(strokeWidth: 2),
                ],
              ],
            ),
          ),
          if (_fileError != null) ...[
            const SizedBox(height: 16),
            _SectionCard(
              child: Text(
                _fileError!,
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

class _StatusTile extends StatelessWidget {
  const _StatusTile({super.key, required this.status, this.onTap});

  final _RuntimeStatus status;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: status.active
                ? const Color(0xFFF2F9FF)
                : const Color(0xFFF6F3F1),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                status.icon,
                size: 18,
                color: status.active ? _accentBlue : _warmMuted,
              ),
              const Spacer(),
              Text(
                status.title,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: _warmMuted,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      status.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: status.active ? _accentBlue : _warmText,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  if (status.latencyMs != null) ...[
                    const SizedBox(width: 6),
                    _LatencyBadge(latencyMs: status.latencyMs!),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LatencyBadge extends StatelessWidget {
  const _LatencyBadge({required this.latencyMs});

  final int latencyMs;

  @override
  Widget build(BuildContext context) {
    final bool isFast = latencyMs < 100;
    final Color dotColor =
        isFast ? const Color(0xFF12B76A) : const Color(0xFFF79009);
    final Color bgColor =
        isFast ? const Color(0x1F12B76A) : const Color(0x1FF79009);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            '${latencyMs}ms',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: dotColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 10,
                ),
          ),
        ],
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
      scaffoldBackgroundColor: Colors.transparent,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _accentBlue,
        brightness: Brightness.light,
        surface: _warmSurface,
      ),
      useMaterial3: true,
    ),
    home: const OverlayBallPage(),
  ));
}

/// 全局悬浮窗内的球：与主页面「长按录音转写」一致，长按录音、松手停止并调用 POST 转写接口。
/// 不调用 resizeOverlay（插件会把 180 当 dp 转成像素，球会突然变大）。拖动由原生 enableDrag 处理。
class OverlayBallPage extends StatefulWidget {
  const OverlayBallPage({
    super.key,
    this.recorder,
    this.tempDirProvider,
    this.transcribeAudio,
    this.nowProvider,
    this.onRecordStartFeedback,
    this.onRecordStopFeedback,
  });

  @visibleForTesting
  final AudioRecorder? recorder;

  @visibleForTesting
  final Future<Directory> Function()? tempDirProvider;

  @visibleForTesting
  final Future<TranscriptionResult> Function(String audioPath)? transcribeAudio;

  @visibleForTesting
  final DateTime Function()? nowProvider;

  @visibleForTesting
  final Future<void> Function()? onRecordStartFeedback;

  @visibleForTesting
  final Future<void> Function()? onRecordStopFeedback;

  @override
  State<OverlayBallPage> createState() => _OverlayBallPageState();
}

class _OverlayBallPageState extends State<OverlayBallPage> {
  late final AudioRecorder _recorder;
  static const Duration _holdRecordMinDuration = Duration(milliseconds: 500);
  DateTime? _holdRecordStartTime;

  @override
  void initState() {
    super.initState();
    _recorder = widget.recorder ?? AudioRecorder();
  }

  DateTime _now() => widget.nowProvider?.call() ?? DateTime.now();

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

  Future<bool> _hasNativeMicrophonePermission() async {
    if (!debugPlatformIsAndroid()) {
      return true;
    }
    try {
      return await _insertTextChannel.invokeMethod<bool>(
            'hasMicrophonePermission',
          ) ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// 悬浮球在独立引擎中运行，record 的 hasPermission() 在 overlay 上下文中常误报无权限（主应用已授权即可录）。
  /// 直接尝试 start，失败再视为无权限。
  Future<void> _startHoldRecord() async {
    try {
      if (!await _hasNativeMicrophonePermission()) {
        _log('[悬浮球] 录制=无权限');
        try {
          await _insertTextChannel.invokeMethod<bool>(
            'requestMicrophonePermission',
          );
        } catch (_) {}
        return;
      }
      final Directory tempDir =
          await (widget.tempDirProvider?.call() ?? getTemporaryDirectory());
      final String path =
          '${tempDir.path}${Platform.pathSeparator}overlay_record_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.wav),
          path: path);
      if (mounted) {
        setState(() => _holdRecordStartTime = _now());
        await (widget.onRecordStartFeedback?.call() ??
            _triggerNativeVibration());
        _log('[悬浮球] 录制=开始');
      }
    } catch (e) {
      final String msg = e.toString().toLowerCase();
      if (msg.contains('permission') || msg.contains('权限')) {
        _log('[悬浮球] 录制=无权限');
        if (debugPlatformIsAndroid()) {
          try {
            await _insertTextChannel
                .invokeMethod<bool>('requestMicrophonePermission');
          } catch (_) {}
        }
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
    await (widget.onRecordStopFeedback?.call() ?? _triggerNativeVibration());
    if (path == null) {
      _log('[悬浮球] 松手=无路径');
      return;
    }
    final Duration duration = _now().difference(startTime);
    if (duration < _holdRecordMinDuration) {
      _log('[悬浮球] 松手=太短 ${duration.inMilliseconds}ms');
      return;
    }
    try {
      _log('[悬浮球] 转写=开始');
      final result = await (widget.transcribeAudio?.call(path) ??
          _transcribeAudioWithCurrentSettings(path));
      _log('[悬浮球] 转写=完成');
      _logLong('[悬浮球] 转写结果: ', result.text);
      FlutterOverlayWindow.shareData('$_insertTextPrefix${result.text}');
      if (debugPlatformIsAndroid() && result.text.isNotEmpty) {
        final accessibilityEnabled =
            await _insertTextChannel.invokeMethod<bool>(
                  'isAccessibilityServiceEnabled',
                ) ??
                false;
        if (!accessibilityEnabled) {
          _log('[悬浮球] 无障碍未开启，打开设置');
          await _insertTextChannel
              .invokeMethod<void>('openAccessibilitySettings');
          return;
        }
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
                      : const Color(0xFFF2F9FF),
                ),
                child: Icon(
                  isRecording ? Icons.stop : Icons.mic_none,
                  color: isRecording
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : _accentBlue,
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
