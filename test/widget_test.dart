// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nprinter_bluetooth_only/main.dart';

void main() {
  testWidgets('App renders printer screen', (WidgetTester tester) async {
    await tester.pumpWidget(const NPrinterBluetoothOnlyApp());
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.text('نص الطباعة'), findsOneWidget);
    expect(find.byIcon(Icons.print), findsOneWidget);
  });
}
