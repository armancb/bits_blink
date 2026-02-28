import 'package:flutter/material.dart';
import '../models/message.dart';
import '../services/encoder_service.dart';
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

  final List<Message> _messages = [];
  List<HudEntry> _hudEntries = [];

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Encodes and sends a message, updating the HUD as it goes.
  void _handleSend(String text) {
    // Step 1: Show encoding-in-progress on HUD.
    setState(() {
      _hudEntries = [
        const HudEntry(tag: 'UTF8', text: 'Converting to binary...'),
        const HudEntry(tag: 'RS', text: 'Reed-Solomon encoding...'),
      ];
    });

    // Step 2: Run the encoding pipeline (prints to debug console).
    EncoderService.encodeAndPrint(text);

    // Step 3: Append the sent message and update HUD to "ready".
    setState(() {
      _messages.add(Message.sent(text));
      _hudEntries = [
        const HudEntry(tag: 'UTF8', text: 'Binary conversion complete'),
        const HudEntry(tag: 'RS', text: 'Parity symbols appended'),
        const HudEntry(tag: 'TX', text: 'Transmission ready ✓'),
      ];
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
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      'Send a message to begin transmission',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 14,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      return MessageBubble(message: _messages[index]);
                    },
                  ),
          ),

          // ── Telemetry HUD ──
          TelemetryHud(entries: _hudEntries),

          // ── Input bar ──
          MessageInput(controller: _controller, onSend: _handleSend),
        ],
      ),
    );
  }
}
