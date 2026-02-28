import 'package:flutter/material.dart';

/// Centralised color palette for the BITSBlink app.
class AppColors {
  AppColors._();

  // ── Primary brand ──
  static const Color primary = Color(0xFF1B5E6B);
  static const Color primaryDark = Color(0xFF144A54);

  // ── Chat bubbles ──
  static const Color sentBubble = Color(0xFF1B5E6B);
  static const Color receivedBubble = Color(0xFFF0F0F0);

  // ── Text ──
  static const Color textOnSent = Colors.white;
  static const Color textOnReceived = Color(0xFF2C2C2C);
  static const Color textSecondary = Color(0xFF8A8A8A);
  static const Color senderLabel = Color(0xFF5A5A5A);

  // ── Backgrounds ──
  static const Color scaffoldBackground = Colors.white;
  static const Color hudBackground = Color(0xFF1A2332);

  // ── Accents ──
  static const Color statusOnline = Color(0xFF4CAF50);
  static const Color readReceipt = Color(0xFF4FC3F7);
  static const Color hudAccent = Color(0xFF4CAF50);

  // ── Input ──
  static const Color inputBackground = Color(0xFFF5F5F5);
  static const Color inputBorder = Color(0xFFE0E0E0);
}
