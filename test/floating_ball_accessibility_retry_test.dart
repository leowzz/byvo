import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:byvo/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const insertTextChannel = MethodChannel('byvo/insert_text');
  const overlayChannel = MethodChannel('x-slayer/overlay_channel');

  late List<bool> accessibilityChecks;
  late int openAccessibilitySettingsCount;
  late int showOverlayCount;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugPlatformIsAndroid = () => true;
    accessibilityChecks = <bool>[false, true];
    openAccessibilitySettingsCount = 0;
    showOverlayCount = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(insertTextChannel, (MethodCall call) async {
      switch (call.method) {
        case 'isAccessibilityServiceEnabled':
          return accessibilityChecks.removeAt(0);
        case 'openAccessibilitySettings':
          openAccessibilitySettingsCount += 1;
          return null;
      }
      return null;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(overlayChannel, (MethodCall call) async {
      switch (call.method) {
        case 'showOverlay':
          showOverlayCount += 1;
          return null;
        case 'isOverlayActive':
          return false;
        case 'requestPermission':
          return true;
        case 'closeOverlay':
          return true;
      }
      return null;
    });
  });

  tearDown(() async {
    debugPlatformIsAndroid = defaultPlatformIsAndroid;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(insertTextChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(overlayChannel, null);
  });

  testWidgets(
      'floating ball auto enables after returning from accessibility settings',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: TranscriptionMvpPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(openAccessibilitySettingsCount, 1);
    expect(showOverlayCount, 0);
    expect(find.text('当前处于关闭状态'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(showOverlayCount, 1);
    expect(find.text('当前处于开启状态'), findsOneWidget);
  });
}
