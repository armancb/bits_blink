import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Reusable text styles for the BITSBlink app.
class AppTextStyles {
  AppTextStyles._();

  // ── Header ──
  static const TextStyle headerTitle = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w800,
    color: AppColors.primaryDark,
    letterSpacing: 0.5,
  );

  static const TextStyle headerSubtitle = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: AppColors.primary,
    letterSpacing: 1.5,
  );

  // ── Chat ──
  static const TextStyle senderName = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: AppColors.senderLabel,
  );

  static const TextStyle messageBody = TextStyle(
    fontSize: 14,
    height: 1.4,
    color: AppColors.textOnReceived,
  );

  static const TextStyle messageSent = TextStyle(
    fontSize: 14,
    height: 1.4,
    color: AppColors.textOnSent,
  );

  static const TextStyle timestamp = TextStyle(
    fontSize: 11,
    color: AppColors.textSecondary,
  );

  static const TextStyle timestampSent = TextStyle(
    fontSize: 11,
    color: Colors.white70,
  );

  // ── Telemetry HUD ──
  static const TextStyle hudTitle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    color: Colors.white70,
    letterSpacing: 2.0,
  );

  static const TextStyle hudLog = TextStyle(
    fontSize: 13,
    fontFamily: 'monospace',
    color: Colors.white60,
    height: 1.8,
  );

  static const TextStyle hudTag = TextStyle(
    fontSize: 13,
    fontFamily: 'monospace',
    fontWeight: FontWeight.w700,
    color: Colors.white,
  );
}
