import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mync/screens/placeholder_screen.dart';

void main() {
  testWidgets('Platzhalter zeigt Titel und Text', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PlaceholderScreen(
          icon: Icons.sync_alt,
          title: 'Sync-Inbox',
          text: 'Kommt bald.',
        ),
      ),
    ));
    expect(find.text('Sync-Inbox'), findsOneWidget);
    expect(find.text('Kommt bald.'), findsOneWidget);
  });
}
