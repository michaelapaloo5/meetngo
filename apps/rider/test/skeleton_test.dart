import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/main.dart';

void main() {
  testWidgets('app boots to a MaterialApp', (tester) async {
    await tester.pumpWidget(const RideNGoApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
