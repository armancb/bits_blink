import 'package:flutter/material.dart';
import '../models/message.dart';
import '../widgets/app_header.dart';
import '../widgets/message_bubble.dart';
import '../widgets/message_input.dart';
import '../widgets/telemetry_hud.dart';

/// Main chat screen for the BITSBlink optical modem interface.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  /// Pre-populated sample conversation.
  final List<Message> _messages = [
    const Message(
      text:
          'Diver 2 here. Ambient light is high. Switching to high-contrast mode.',
      timestamp: '14:02:33',
      isSentByMe: false,
      senderName: 'Diver 2',
    ),
    const Message(
      text: 'Copy that. Filters applied. Readability check?',
      timestamp: '14:03:10',
      isSentByMe: true,
      senderName: 'Surface',
    ),
    const Message(
      text: 'Crystal clear. Proceeding to target coordinates.',
      timestamp: '14:04:45',
      isSentByMe: false,
      senderName: 'Diver 2',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Appends a new sent message and scrolls to the bottom.
  void _handleSend(String text) {
    setState(() {
      _messages.add(Message.sent(text));
    });

    // Scroll to bottom after the frame renders.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // ── Header ──
          const AppHeader(),

          // ── Messages list ──
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                return MessageBubble(message: _messages[index]);
              },
            ),
          ),

          // ── Telemetry HUD ──
          const TelemetryHud(),

          // ── Input bar ──
          MessageInput(controller: _controller, onSend: _handleSend),
        ],
      ),
    );
  }
}
