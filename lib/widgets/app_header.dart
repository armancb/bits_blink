import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// Top header bar showing BITSBlink branding and connection status.
class AppHeader extends StatelessWidget {
  const AppHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: const BoxDecoration(
        color: AppColors.scaffoldBackground,
        border: Border(
          bottom: BorderSide(color: AppColors.inputBorder, width: 0.5),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // ── Branding ──
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('BITSBlink', style: AppTextStyles.headerTitle),
                SizedBox(height: 2),
                Text(
                  'OPTICAL MODEM INTERFACE',
                  style: AppTextStyles.headerSubtitle,
                ),
              ],
            ),

            // ── Status indicator ──
            Container(
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                color: AppColors.statusOnline,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
