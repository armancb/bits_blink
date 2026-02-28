import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bits_blink/main.dart';

void main() {
  testWidgets('Chat screen renders header and empty state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const BitsBlinkApp());

    // Header should show branding.
    expect(find.text('BITSBlink'), findsOneWidget);
    expect(find.text('OPTICAL MODEM INTERFACE'), findsOneWidget);

    // Empty state message.
    expect(find.text('Send a message to begin transmission'), findsOneWidget);

    // Telemetry HUD should render with idle state.
    expect(find.text('TELEMETRY HUD'), findsOneWidget);
    expect(find.text('Awaiting transmission...'), findsOneWidget);

    // Input field should be present.
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('Sending a message appends it and updates HUD', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const BitsBlinkApp());

    // Type a message and tap send.
    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.tap(find.byIcon(Icons.flash_on));
    await tester.pumpAndSettle();

    // The sent message should now be visible.
    expect(find.text('Hello'), findsOneWidget);

    // HUD should show encoding-complete status (rendered via RichText).
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().contains('Transmission ready'),
      ),
      findsOneWidget,
    );
  });
}
