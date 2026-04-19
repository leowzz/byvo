import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:byvo/main.dart';
import 'package:byvo/transcription/transcription_result.dart';

class _FakeAudioRecorder extends AudioRecorder {
  _FakeAudioRecorder({required this.stopResult, this.startError});

  final String? stopResult;
  final Object? startError;
  int startCallCount = 0;
  int stopCallCount = 0;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    startCallCount += 1;
    if (startError != null) {
      throw startError!;
    }
  }

  @override
  Future<String?> stop() async {
    stopCallCount += 1;
    return stopResult;
  }
}

void main() {
  testWidgets('MyApp renders transcription shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('byvo · 豆包'), findsOneWidget);
    expect(find.text('转写'), findsOneWidget);
  });

  testWidgets('Overlay ball has no container shadow', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: OverlayBallPage()));
    await tester.pump();

    final AnimatedContainer container = tester.widget(
      find.descendant(
        of: find.byType(OverlayBallPage),
        matching: find.byType(AnimatedContainer),
      ),
    );

    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.boxShadow, anyOf(isNull, isEmpty));
  });

  testWidgets('Overlay ball emits haptic feedback on record start and stop',
      (WidgetTester tester) async {
    final recorder = _FakeAudioRecorder(stopResult: '/tmp/fake.wav');
    int startFeedbackCount = 0;
    int stopFeedbackCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: OverlayBallPage(
          recorder: recorder,
          tempDirProvider: () async => Directory.systemTemp,
          transcribeAudio: (_) async => const TranscriptionResult(text: ''),
          onRecordStartFeedback: () async {
            startFeedbackCount += 1;
          },
          onRecordStopFeedback: () async {
            stopFeedbackCount += 1;
          },
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(tester.getCenter(find.byType(GestureDetector)));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(recorder.startCallCount, 1);
    expect(recorder.stopCallCount, 1);
    expect(startFeedbackCount, 1);
    expect(stopFeedbackCount, 1);
  });

  testWidgets('Overlay ball uses native vibrate feedback on record start and stop',
      (WidgetTester tester) async {
    final recorder = _FakeAudioRecorder(stopResult: '/tmp/fake.wav');
    const insertTextChannel = MethodChannel('byvo/insert_text');
    final calls = <String>[];
    debugPlatformIsAndroid = () => true;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(insertTextChannel, (MethodCall call) async {
      calls.add(call.method);
      return null;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: OverlayBallPage(
          recorder: recorder,
          tempDirProvider: () async => Directory.systemTemp,
          transcribeAudio: (_) async => const TranscriptionResult(text: ''),
        ),
      ),
    );
    await tester.pump();

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(GestureDetector)));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      calls.where((method) => method == 'vibrate').length,
      2,
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(insertTextChannel, null);
    debugPlatformIsAndroid = defaultPlatformIsAndroid;
  });

  testWidgets(
      'Overlay ball prompts accessibility settings when transcription cannot be inserted',
      (WidgetTester tester) async {
    final recorder = _FakeAudioRecorder(stopResult: '/tmp/fake.wav');
    const insertTextChannel = MethodChannel('byvo/insert_text');
    final calls = <String>[];
    var now = DateTime(2026, 1, 1, 0, 0, 0);
    debugPlatformIsAndroid = () => true;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(insertTextChannel, (MethodCall call) async {
      calls.add(call.method);
      if (call.method == 'isAccessibilityServiceEnabled') {
        return false;
      }
      return null;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: OverlayBallPage(
          recorder: recorder,
          tempDirProvider: () async => Directory.systemTemp,
          transcribeAudio: (_) async => const TranscriptionResult(text: 'hello'),
          nowProvider: () => now,
        ),
      ),
    );
    await tester.pump();

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(GestureDetector)));
    await tester.pump(const Duration(milliseconds: 700));
    now = now.add(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(calls.where((method) => method == 'openAccessibilitySettings').length, 1);
    expect(calls.where((method) => method == 'insertTextToFocusedField'), isEmpty);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(insertTextChannel, null);
    debugPlatformIsAndroid = defaultPlatformIsAndroid;
  });

  testWidgets(
      'Overlay ball checks native microphone permission before recording',
      (WidgetTester tester) async {
    final recorder = _FakeAudioRecorder(stopResult: '/tmp/fake.wav');
    const insertTextChannel = MethodChannel('byvo/insert_text');
    final calls = <String>[];
    var transcribeCallCount = 0;
    debugPlatformIsAndroid = () => true;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(insertTextChannel, (MethodCall call) async {
      calls.add(call.method);
      if (call.method == 'hasMicrophonePermission') {
        return false;
      }
      return null;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: OverlayBallPage(
          recorder: recorder,
          tempDirProvider: () async => Directory.systemTemp,
          transcribeAudio: (_) async {
            transcribeCallCount += 1;
            return const TranscriptionResult(text: '');
          },
        ),
      ),
    );
    await tester.pump();

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(GestureDetector)));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(recorder.startCallCount, 0);
    expect(recorder.stopCallCount, 0);
    expect(transcribeCallCount, 0);
    expect(calls.where((method) => method == 'hasMicrophonePermission').length, 1);
    expect(
      calls.where((method) => method == 'requestMicrophonePermission').length,
      1,
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(insertTextChannel, null);
    debugPlatformIsAndroid = defaultPlatformIsAndroid;
  });

  testWidgets(
      'Overlay ball requests microphone permission via main activity when recording permission is missing',
      (WidgetTester tester) async {
    final recorder = _FakeAudioRecorder(
      stopResult: null,
      startError: StateError('permission denied'),
    );
    const insertTextChannel = MethodChannel('byvo/insert_text');
    final calls = <String>[];
    debugPlatformIsAndroid = () => true;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(insertTextChannel, (MethodCall call) async {
      calls.add(call.method);
      return null;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: OverlayBallPage(
          recorder: recorder,
          tempDirProvider: () async => Directory.systemTemp,
          transcribeAudio: (_) async => const TranscriptionResult(text: ''),
        ),
      ),
    );
    await tester.pump();

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(GestureDetector)));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(recorder.startCallCount, 1);
    expect(
      calls.where((method) => method == 'requestMicrophonePermission').length,
      1,
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(insertTextChannel, null);
    debugPlatformIsAndroid = defaultPlatformIsAndroid;
  });

  testWidgets('Home hold-to-transcribe uses native vibrate feedback on record start and stop',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final recorder = _FakeAudioRecorder(stopResult: null);
    const insertTextChannel = MethodChannel('byvo/insert_text');
    final calls = <String>[];
    debugPlatformIsAndroid = () => true;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(insertTextChannel, (MethodCall call) async {
      calls.add(call.method);
      if (call.method == 'isAccessibilityServiceEnabled') {
        return true;
      }
      return null;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: TranscriptionMvpPage(
          recorder: recorder,
          tempDirProvider: () async => Directory.systemTemp,
          transcribeAudio: (_) async => const TranscriptionResult(text: ''),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TranscriptionMvpPage), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, -800));
    await tester.pumpAndSettle();

    expect(find.byKey(homeHoldToTranscribeKey), findsOneWidget);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(homeHoldToTranscribeKey)),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(recorder.startCallCount, 1);
    expect(recorder.stopCallCount, 1);
    expect(
      calls.where((method) => method == 'vibrate').length,
      2,
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(insertTextChannel, null);
    debugPlatformIsAndroid = defaultPlatformIsAndroid;
  });
}
