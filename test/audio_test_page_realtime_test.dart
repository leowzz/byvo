import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:byvo/main.dart';

class _FakeRealtimeAdapter implements RealtimeTranscriptionAdapter {
  int startCallCount = 0;
  int stopCallCount = 0;
  bool disposed = false;
  bool isStarted = false;
  bool? lastEffect;
  bool? lastUseLlm;
  int? lastIdleTimeoutSec;
  Completer<void>? startCompleter;
  Object? startError;

  final StreamController<String> _textController =
      StreamController<String>.broadcast();
  final StreamController<void> _closedController =
      StreamController<void>.broadcast();

  @override
  Stream<String> get textStream => _textController.stream;

  @override
  Stream<void> get connectionClosedStream => _closedController.stream;

  @override
  Future<void> start({
    bool effect = false,
    bool useLlm = false,
    int? idleTimeoutSec,
  }) async {
    startCallCount += 1;
    isStarted = true;
    lastEffect = effect;
    lastUseLlm = useLlm;
    lastIdleTimeoutSec = idleTimeoutSec;
    if (startCompleter != null) {
      await startCompleter!.future;
    }
    if (startError != null) {
      throw startError!;
    }
  }

  @override
  Future<void> stop() async {
    stopCallCount += 1;
    isStarted = false;
  }

  @override
  void dispose() {
    disposed = true;
    _textController.close();
    _closedController.close();
  }

  void emitText(String value) => _textController.add(value);
  void emitTextError(Object error) => _textController.addError(error);

  void emitClosed() => _closedController.add(null);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
      'realtime card renders above the text insertion verification card',
      (WidgetTester tester) async {
    final fakeRealtime = _FakeRealtimeAdapter();

    await tester.pumpWidget(
      MaterialApp(
        home: AudioTestPage(
          realtimeAdapterFactory: () => fakeRealtime,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final realtimeTopLeft =
        tester.getTopLeft(find.byKey(audioTestRealtimeCardKey));
    final insertionTopLeft =
        tester.getTopLeft(find.byKey(audioTestTextInsertionCardKey));

    expect(realtimeTopLeft.dy, lessThan(insertionTopLeft.dy));
  });

  testWidgets(
      'start listening updates state and renders streamed realtime text',
      (WidgetTester tester) async {
    final fakeRealtime = _FakeRealtimeAdapter();
    final startCompleter = Completer<void>();
    fakeRealtime.startCompleter = startCompleter;

    await tester.pumpWidget(
      MaterialApp(
        home: AudioTestPage(
          realtimeAdapterFactory: () => fakeRealtime,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(audioTestRealtimeToggleButtonKey));
    await tester.pump();

    expect(fakeRealtime.startCallCount, 1);
    expect(find.text('连接中…'), findsOneWidget);
    expect(find.textContaining('连接中'), findsWidgets);
    expect(find.text('停止监听'), findsNothing);

    startCompleter.complete();
    await tester.pump();
    await tester.pump();

    expect(find.text('停止监听'), findsOneWidget);
    expect(find.textContaining('实时监听中'), findsOneWidget);

    fakeRealtime.emitText('你好，实时文本');
    await tester.pump();

    expect(find.text('你好，实时文本'), findsOneWidget);
  });

  testWidgets(
      'idle close exits listening state and shows auto-disconnected status',
      (WidgetTester tester) async {
    final fakeRealtime = _FakeRealtimeAdapter();

    await tester.pumpWidget(
      MaterialApp(
        home: AudioTestPage(
          realtimeAdapterFactory: () => fakeRealtime,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(audioTestRealtimeToggleButtonKey));
    await tester.pump();
    expect(find.text('停止监听'), findsOneWidget);

    fakeRealtime.emitClosed();
    await tester.pumpAndSettle();

    expect(find.text('开始连续监听'), findsOneWidget);
    expect(find.textContaining('自动断开'), findsOneWidget);
  });

  testWidgets(
      'startup failure preserves previous text and shows realtime error only',
      (WidgetTester tester) async {
    final fakeRealtime = _FakeRealtimeAdapter();

    await tester.pumpWidget(
      MaterialApp(
        home: AudioTestPage(
          realtimeAdapterFactory: () => fakeRealtime,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(audioTestRealtimeToggleButtonKey));
    await tester.pump();
    await tester.pump();
    expect(find.text('停止监听'), findsOneWidget);
    fakeRealtime.emitText('保留文本');
    await tester.pump();
    await tester.tap(find.byKey(audioTestRealtimeToggleButtonKey));
    await tester.pumpAndSettle();
    if (find.text('停止监听').evaluate().isNotEmpty) {
      await tester.tap(find.byKey(audioTestRealtimeToggleButtonKey));
      await tester.pumpAndSettle();
    }
    expect(find.text('停止监听'), findsNothing);

    fakeRealtime.startError = StateError('实时启动失败');
    await tester.tap(find.byKey(audioTestRealtimeToggleButtonKey));
    await tester.pumpAndSettle();

    expect(find.text('保留文本'), findsOneWidget);
    expect(find.textContaining('实时启动失败'), findsOneWidget);
    expect(find.text('请先录音'), findsNothing);
  });

  testWidgets('card copy matches approved realtime design',
      (WidgetTester tester) async {
    final fakeRealtime = _FakeRealtimeAdapter();

    await tester.pumpWidget(
      MaterialApp(
        home: AudioTestPage(
          realtimeAdapterFactory: () => fakeRealtime,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('实时转写'), findsOneWidget);
    expect(find.textContaining('开始连续监听'), findsWidgets);
    expect(find.textContaining('空闲'), findsOneWidget);
    expect(find.textContaining('自动停止'), findsOneWidget);
  });

  testWidgets('startup failure is recoverable and later retry can succeed',
      (WidgetTester tester) async {
    final failedAdapter = _FakeRealtimeAdapter()
      ..startError = StateError('首启失败');
    final successAdapter = _FakeRealtimeAdapter();
    var factoryCallCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: AudioTestPage(
          realtimeAdapterFactory: () {
            factoryCallCount += 1;
            return factoryCallCount == 1 ? failedAdapter : successAdapter;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(audioTestRealtimeToggleButtonKey));
    await tester.pumpAndSettle();
    expect(find.textContaining('首启失败'), findsOneWidget);
    expect(find.text('开始连续监听'), findsOneWidget);

    await tester.tap(find.byKey(audioTestRealtimeToggleButtonKey));
    await tester.pumpAndSettle();

    expect(factoryCallCount, 2);
    expect(successAdapter.startCallCount, 1);
    expect(find.text('停止监听'), findsOneWidget);
    expect(find.textContaining('实时监听中'), findsOneWidget);
  });

  testWidgets(
      'realtime text stream async error surfaces in UI and exits listening cleanly',
      (WidgetTester tester) async {
    final adapter = _FakeRealtimeAdapter();

    await tester.pumpWidget(
      MaterialApp(
        home: AudioTestPage(
          realtimeAdapterFactory: () => adapter,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(audioTestRealtimeToggleButtonKey));
    await tester.pumpAndSettle();
    expect(find.text('停止监听'), findsOneWidget);

    adapter.emitTextError(StateError('流式异常'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('开始连续监听'), findsOneWidget);
    expect(find.textContaining('流式异常'), findsOneWidget);
  });

  testWidgets(
      'connection close during startup ends in auto-disconnected state instead of listening',
      (WidgetTester tester) async {
    final adapter = _FakeRealtimeAdapter();
    final startCompleter = Completer<void>();
    adapter.startCompleter = startCompleter;

    await tester.pumpWidget(
      MaterialApp(
        home: AudioTestPage(
          realtimeAdapterFactory: () => adapter,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(audioTestRealtimeToggleButtonKey));
    await tester.pump();
    expect(find.text('连接中…'), findsOneWidget);

    adapter.emitClosed();
    await tester.pump();
    startCompleter.complete();
    await tester.pumpAndSettle();

    expect(find.text('停止监听'), findsNothing);
    expect(find.text('开始连续监听'), findsOneWidget);
    expect(find.textContaining('自动断开'), findsOneWidget);
    expect(adapter.disposed, isTrue);
  });
}
