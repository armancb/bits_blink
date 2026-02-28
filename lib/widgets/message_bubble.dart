import 'package:flutter/material.dart';
import '../models/message.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// A chat bubble that renders as sent (right) or received (left).
class MessageBubble extends StatelessWidget {
  final Message message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return message.isSentByMe ? _buildSentBubble() : _buildReceivedBubble();
  }

  // ── Sent (right-aligned, dark teal) ──
  Widget _buildSentBubble() {
    return Padding(
      padding: const EdgeInsets.only(left: 64, right: 16, top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Sender label
          Padding(
            padding: const EdgeInsets.only(bottom: 4, right: 4),
            child: Text(
              message.senderName,
              style: AppTextStyles.senderName.copyWith(
                color: AppColors.primary,
              ),
            ),
          ),

          // Bubble
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.sentBubble,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(18),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Text(message.text, style: AppTextStyles.messageSent),
          ),

          // Timestamp + read receipt
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(message.timestamp, style: AppTextStyles.timestamp),
                const SizedBox(width: 4),
                Icon(Icons.done_all, size: 14, color: AppColors.readReceipt),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Received (left-aligned, light grey) ──
  Widget _buildReceivedBubble() {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 64, top: 8, bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Avatar
          CircleAvatar(
            radius: 16,
            backgroundColor: AppColors.primary.withValues(alpha: 0.15),
            child: Icon(Icons.person, size: 18, color: AppColors.primary),
          ),
          const SizedBox(width: 8),

          // Bubble column
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Sender label
                Padding(
                  padding: const EdgeInsets.only(bottom: 4, left: 4),
                  child: Text(
                    message.senderName,
                    style: AppTextStyles.senderName,
                  ),
                ),

                // Bubble
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.receivedBubble,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(18),
                      topRight: Radius.circular(18),
                      bottomLeft: Radius.circular(4),
                      bottomRight: Radius.circular(18),
                    ),
                  ),
                  child: Text(message.text, style: AppTextStyles.messageBody),
                ),

                // Timestamp
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 4),
                  child: Text(
                    message.timestamp,
                    style: AppTextStyles.timestamp,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
