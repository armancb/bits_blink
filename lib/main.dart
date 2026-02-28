import 'package:flutter/material.dart';
import 'screens/chat_screen.dart';

void main() {
  runApp(const BitsBlinkApp());
}

/// Root widget for the BITSBlink application.
class BitsBlinkApp extends StatelessWidget {
  const BitsBlinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BITSBlink',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF1B5E6B),
      ),
      home: const ChatScreen(),
    );
  }
}
