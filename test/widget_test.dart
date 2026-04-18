import 'package:flutter_test/flutter_test.dart';

import 'package:byvo/main.dart';

void main() {
  testWidgets('MyApp renders transcription shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('byvo · 豆包'), findsOneWidget);
    expect(find.text('转写'), findsOneWidget);
  });
}
