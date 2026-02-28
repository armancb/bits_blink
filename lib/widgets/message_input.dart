import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Message input bar with a rounded text field and flash-icon send button.
class MessageInput extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onSend;

  const MessageInput({
    super.key,
    required this.controller,
    required this.onSend,
  });

  void _handleSend() {
    final text = controller.text.trim();
    if (text.isEmpty) return;
    onSend(text);
    controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.scaffoldBackground,
        border: const Border(
          top: BorderSide(color: AppColors.inputBorder, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // ── Text field ──
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.inputBackground,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: AppColors.inputBorder),
                ),
                child: TextField(
                  controller: controller,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _handleSend(),
                  decoration: const InputDecoration(
                    hintText: 'Type message...',
                    hintStyle: TextStyle(color: AppColors.textSecondary),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),

            // ── Send button ──
            GestureDetector(
              onTap: _handleSend,
              child: Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.flash_on,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
