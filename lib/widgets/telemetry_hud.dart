import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// A single telemetry log entry (tag + message).
class HudEntry {
  final String tag;
  final String text;

  const HudEntry({required this.tag, required this.text});
}

/// Dark telemetry HUD panel showing dynamic optical modem status lines.
class TelemetryHud extends StatelessWidget {
  final List<HudEntry> entries;

  const TelemetryHud({super.key, this.entries = const []});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.hudBackground,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row ──
          Row(
            children: [
              const Text('TELEMETRY HUD', style: AppTextStyles.hudTitle),
              const Spacer(),
              _pulseDot(),
            ],
          ),
          const SizedBox(height: 12),

          // ── Log entries ──
          if (entries.isEmpty)
            Text('Awaiting transmission...', style: AppTextStyles.hudLog)
          else
            for (final entry in entries)
              _logLine(tag: entry.tag, text: entry.text),
        ],
      ),
    );
  }

  /// Green status dot.
  Widget _pulseDot() {
    return Container(
      width: 8,
      height: 8,
      decoration: const BoxDecoration(
        color: AppColors.hudAccent,
        shape: BoxShape.circle,
      ),
    );
  }

  /// A single log line like `[PHY]  Some status text`.
  Widget _logLine({required String tag, required String text}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(text: '[$tag]', style: AppTextStyles.hudTag),
            const TextSpan(text: '  '),
            TextSpan(text: text, style: AppTextStyles.hudLog),
          ],
        ),
      ),
    );
  }
}
