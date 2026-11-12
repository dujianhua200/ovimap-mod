import 'package:flutter_test/flutter_test.dart';

import 'package:ovimap/main.dart';

void main() {
  testWidgets('app boots to home', (tester) async {
    await tester.pumpWidget(const OviMapApp());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('滑洲云图 启动中…'), findsOneWidget);
  });
}
