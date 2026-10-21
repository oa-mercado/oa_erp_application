import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oa_erp_application/main.dart';

void main() {
  testWidgets('App starts smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OrangeAppsRfidApp()));
    expect(find.byType(OrangeAppsRfidApp), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
