import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:byvo/main.dart';

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
}
