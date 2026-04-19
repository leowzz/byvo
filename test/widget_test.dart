import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:byvo/main.dart';
import 'package:byvo/transcription/transcription_result.dart';

class _FakeAudioRecorder extends AudioRecorder {
  _FakeAudioRecorder({required this.stopResult});

  final String? stopResult;
  int startCallCount = 0;
  int stopCallCount = 0;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    startCallCount += 1;
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
