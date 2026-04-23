import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:byvo/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const insertTextChannel = MethodChannel('byvo/insert_text');
  const overlayChannel = MethodChannel('x-slayer/overlay_channel');

  late bool accessibilityEnabled;
  late int openAccessibilitySettingsCount;
  late int showOverlayCount;

  setUp(() async {
    PackageInfo.setMockInitialValues(
      appName: 'byvo',
      packageName: 'cn.wleo.byvo',
      version: '1.2.3',
      buildNumber: '45',
      buildSignature: 'test',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugPlatformIsAndroid = () => true;
    accessibilityEnabled = false;
    openAccessibilitySettingsCount = 0;
    showOverlayCount = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(insertTextChannel, (MethodCall call) async {
      switch (call.method) {
        case 'isAccessibilityServiceEnabled':
          return accessibilityEnabled;
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
      'floating ball opens accessibility settings when enabling requires authorization',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('首页'), findsWidgets);
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('悬浮球已关闭'), findsOneWidget);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(openAccessibilitySettingsCount, 1);
    expect(showOverlayCount, 0);
    expect(find.text('悬浮球已开启'), findsOneWidget);

  });

  testWidgets(
      'floating ball intent stays enabled after app restart once accessibility is granted',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(openAccessibilitySettingsCount, 1);
    expect(showOverlayCount, 0);

    accessibilityEnabled = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(showOverlayCount, 1);
    expect(find.text('悬浮球已开启'), findsOneWidget);
  });
}
