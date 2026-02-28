import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bits_blink/main.dart';

void main() {
  testWidgets('Chat screen renders header and sample messages', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const BitsBlinkApp());

    // Header should show branding.
    expect(find.text('BITSBlink'), findsOneWidget);
    expect(find.text('OPTICAL MODEM INTERFACE'), findsOneWidget);

    // Sample messages should be visible.
    expect(find.textContaining('Diver 2 here'), findsOneWidget);
    expect(find.textContaining('Copy that'), findsOneWidget);
    expect(find.textContaining('Crystal clear'), findsOneWidget);

    // Telemetry HUD should render.
    expect(find.text('TELEMETRY HUD'), findsOneWidget);

    // Input field should be present.
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('Sending a message appends it to the chat', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const BitsBlinkApp());

    // Type a message and tap send.
    await tester.enterText(find.byType(TextField), 'Hello from Surface');
    await tester.tap(find.byIcon(Icons.flash_on));
    await tester.pumpAndSettle();

    // The sent message should now be visible.
    expect(find.text('Hello from Surface'), findsOneWidget);
  });
}
