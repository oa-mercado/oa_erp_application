import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oa_erp_application/main.dart';

void main() {
  testWidgets('App starts smoke test', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: OrangeAppsRfidApp()));
    expect(find.byType(OrangeAppsRfidApp), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
