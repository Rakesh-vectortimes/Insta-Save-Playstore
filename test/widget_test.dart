import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:instasave/app.dart';

void main() {
  testWidgets('App launches with splash screen', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: InstaSaveApp(),
      ),
    );

    expect(find.text('No Login Required'), findsOneWidget);
  });
}
