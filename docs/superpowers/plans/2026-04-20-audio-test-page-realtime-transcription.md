# Audio Test Page Realtime Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a realtime transcription card to the top of the audio test page that mirrors the existing continuous-listening WebSocket behavior while preserving the current file-upload test flow below it.

**Architecture:** Extend `AudioTestPage` in `lib/main.dart` with a dedicated realtime state machine that owns a `RealtimeStreamEngine` instance, subscribes to incremental text and connection-closed events, and renders a new top card with start/stop controls and status text. Keep realtime state isolated from the existing file-based recording/transcription state so the two test modes can be used independently on the same page.

**Tech Stack:** Flutter, Dart, existing `RealtimeStreamEngine`, existing backend config helpers, existing `flutter_test` widget test framework

---

### Task 1: Add realtime test page state and UI

**Files:**
- Modify: `lib/main.dart`
- Test: `test/audio_test_page_realtime_test.dart`

- [ ] **Step 1: Write the failing widget tests**

Create `test/audio_test_page_realtime_test.dart` with focused tests for the new card ordering and realtime status transitions. Use a lightweight fake engine interface introduced in the page code so the widget test can drive text and close events deterministically.

```dart
import 'dart:async';
import 'dart:io';

import 'package:byvo/main.dart';
import 'package:byvo/transcription/transcription_result.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeRealtimeController {
  final StreamController<String> textController =
      StreamController<String>.broadcast();
  final StreamController<void> closeController =
      StreamController<void>.broadcast();
  bool started = false;
  bool stopped = false;

  Stream<String> get textStream => textController.stream;
  Stream<void> get connectionClosedStream => closeController.stream;

  Future<void> start({
    bool effect = false,
    bool useLlm = false,
    int? idleTimeoutSec,
  }) async {
    started = true;
  }

  Future<void> stop() async {
    stopped = true;
  }

  void dispose() {
    textController.close();
    closeController.close();
  }
}

void main() {
  testWidgets('realtime card is shown before text insertion section',
      (tester) async {
    final fake = FakeRealtimeController();
    await tester.pumpWidget(
      MaterialApp(
        home: AudioTestPage(
          createRealtimeEngine: () => fake,
        ),
      ),
    );

    final realtimeTitle = find.text('实时转写');
    final insertTitle = find.text('文本填入验证');

    expect(realtimeTitle, findsOneWidget);
    expect(insertTitle, findsOneWidget);
    expect(
      tester.getTopLeft(realtimeTitle).dy,
      lessThan(tester.getTopLeft(insertTitle).dy),
    );
  });

  testWidgets('start listening shows streamed text and idle close status',
      (tester) async {
    final fake = FakeRealtimeController();
    await tester.pumpWidget(
      MaterialApp(
        home: AudioTestPage(
          createRealtimeEngine: () => fake,
        ),
      ),
    );

    await tester.tap(find.text('开始实时转写'));
    await tester.pump();

    expect(fake.started, isTrue);
    expect(find.text('正在监听'), findsOneWidget);

    fake.textController.add('你好，世界');
    await tester.pump();
    expect(find.text('你好，世界'), findsOneWidget);

    fake.closeController.add(null);
    await tester.pump();
    expect(find.text('已因空闲自动断开'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
flutter test test/audio_test_page_realtime_test.dart
```

Expected:
- FAIL because `AudioTestPage` does not yet accept a realtime engine factory
- FAIL because the new realtime card/button/status strings do not exist yet

- [ ] **Step 3: Write minimal implementation in `lib/main.dart`**

Update `AudioTestPage` to support a testable realtime engine factory, realtime state, subscriptions, and the new top card. Keep the existing file-upload logic unchanged below it.

Code changes to make:

```dart
abstract class AudioTestRealtimeEngine {
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

class AudioTestRealtimeEngineAdapter implements AudioTestRealtimeEngine {
  AudioTestRealtimeEngineAdapter(this._inner);

  final RealtimeStreamEngine _inner;

  @override
  Stream<String> get textStream => _inner.textStream;

  @override
  Stream<void> get connectionClosedStream => _inner.connectionClosedStream;

  @override
  Future<void> start({
    bool effect = false,
    bool useLlm = false,
    int? idleTimeoutSec,
  }) {
    return _inner.start(
      effect: effect,
      useLlm: useLlm,
      idleTimeoutSec: idleTimeoutSec,
    );
  }

  @override
  Future<void> stop() => _inner.stop();

  @override
  void dispose() => _inner.dispose();
}
```

Add a factory to `AudioTestPage`:

```dart
final AudioTestRealtimeEngine Function()? createRealtimeEngine;
```

Add state fields in `_AudioTestPageState`:

```dart
AudioTestRealtimeEngine? _realtimeEngine;
StreamSubscription<String>? _realtimeTextSub;
StreamSubscription<void>? _realtimeCloseSub;
String _realtimeText = '';
String? _realtimeError;
bool _isRealtimeStarting = false;
bool _isRealtimeListening = false;
bool _realtimeAutoDisconnected = false;
```

Add lifecycle cleanup:

```dart
@override
void dispose() {
  _realtimeTextSub?.cancel();
  _realtimeCloseSub?.cancel();
  _realtimeEngine?.dispose();
  _testInputController.dispose();
  super.dispose();
}
```

Add helpers:

```dart
Future<void> _startRealtimeTranscription() async {
  if (_isRealtimeStarting || _isRealtimeListening) return;
  setState(() {
    _isRealtimeStarting = true;
    _realtimeError = null;
    _realtimeAutoDisconnected = false;
    _realtimeText = '';
  });

  final engine =
      widget.createRealtimeEngine?.call() ??
      AudioTestRealtimeEngineAdapter(RealtimeStreamEngine());

  _realtimeTextSub?.cancel();
  _realtimeCloseSub?.cancel();
  _realtimeEngine?.dispose();
  _realtimeEngine = engine;

  _realtimeTextSub = engine.textStream.listen((text) {
    if (!mounted) return;
    setState(() {
      _realtimeText = text;
      _realtimeError = null;
    });
  }, onError: (Object error, StackTrace stackTrace) {
    if (!mounted) return;
    setState(() {
      _isRealtimeStarting = false;
      _isRealtimeListening = false;
      _realtimeError = error.toString();
    });
  });

  _realtimeCloseSub = engine.connectionClosedStream.listen((_) {
    if (!mounted) return;
    setState(() {
      _isRealtimeStarting = false;
      _isRealtimeListening = false;
      _realtimeAutoDisconnected = true;
    });
  });

  try {
    final effect = await loadEffectTranscribe();
    await engine.start(effect: effect, useLlm: false);
    if (!mounted) return;
    setState(() {
      _isRealtimeStarting = false;
      _isRealtimeListening = true;
    });
  } catch (e, st) {
    logError(e, st, 'Audio test realtime start error');
    if (!mounted) return;
    setState(() {
      _isRealtimeStarting = false;
      _isRealtimeListening = false;
      _realtimeError = e.toString();
    });
  }
}

Future<void> _stopRealtimeTranscription() async {
  final engine = _realtimeEngine;
  if (engine == null) return;
  try {
    await engine.stop();
  } catch (e, st) {
    logError(e, st, 'Audio test realtime stop error');
  }
  if (!mounted) return;
  setState(() {
    _isRealtimeStarting = false;
    _isRealtimeListening = false;
    _realtimeAutoDisconnected = false;
  });
}

String _realtimeStatusText() {
  if (_isRealtimeStarting) return '正在连接';
  if (_isRealtimeListening) return '正在监听';
  if (_realtimeAutoDisconnected) return '已因空闲自动断开';
  if (_realtimeError != null) return '启动失败';
  if (_realtimeText.isNotEmpty) return '已停止';
  return '未启动';
}
```

Insert the new top card before the text insertion card:

```dart
_SectionCard(
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _SectionTitle(
        title: '实时转写',
        subtitle: '点按开始持续监听，长时间无新结果会自动断开',
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _isRealtimeStarting
            ? null
            : (_isRealtimeListening
                  ? _stopRealtimeTranscription
                  : _startRealtimeTranscription),
        icon: Icon(
          _isRealtimeListening ? Icons.stop_circle_outlined : Icons.hearing,
        ),
        label: Text(
          _isRealtimeListening ? '停止实时转写' : '开始实时转写',
        ),
      ),
      const SizedBox(height: 12),
      Text(
        _realtimeStatusText(),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: _warmMuted,
            ),
      ),
      if (_realtimeText.isNotEmpty) ...[
        const SizedBox(height: 12),
        SelectableText(_realtimeText),
      ],
      if (_isRealtimeStarting) ...[
        const SizedBox(height: 12),
        const CircularProgressIndicator(strokeWidth: 2),
      ],
      if (_realtimeError != null) ...[
        const SizedBox(height: 12),
        Text(
          _realtimeError!,
          style: const TextStyle(color: Color(0xFFB42318)),
        ),
      ],
    ],
  ),
),
const SizedBox(height: 16),
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
flutter test test/audio_test_page_realtime_test.dart
```

Expected:
- PASS
- verifies the realtime card is rendered above the text insertion card
- verifies start, streamed text rendering, and idle auto-disconnect status

- [ ] **Step 5: Run focused regression verification**

Run:

```bash
flutter analyze lib/main.dart test/audio_test_page_realtime_test.dart
```

Expected:
- PASS with no new analyzer errors in the modified files

- [ ] **Step 6: Commit**

```bash
git add lib/main.dart test/audio_test_page_realtime_test.dart
git commit -m "feat: add realtime transcription to audio test page"
```
