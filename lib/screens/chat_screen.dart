import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  static const _modemChannel = MethodChannel('bitsblink/modem');

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

  /// Encodes, modulates, transmits via flashlight, and shows the message.
  Future<void> _handleSend(String text) async {
    // Step 1: Show encoding-in-progress on HUD.
    setState(() {
      _hudEntries = [
        const HudEntry(tag: 'UTF8', text: 'Converting to binary...'),
        const HudEntry(tag: 'RS', text: 'Reed-Solomon encoding...'),
        const HudEntry(tag: '4PPM', text: 'Modulating...'),
      ];
    });

    // Step 2: Run full pipeline — UTF-8 → RS → 4-PPM → get signal.
    final signal = EncoderService.encode(text);
    debugPrint('  Signal length: ${signal.length} chips');

    // Step 3: Send signal to native flashlight via MethodChannel.
    setState(() {
      _hudEntries = [
        const HudEntry(tag: 'UTF8', text: 'Binary conversion complete'),
        const HudEntry(tag: 'RS', text: 'Parity symbols appended'),
        const HudEntry(tag: '4PPM', text: 'Modulation complete'),
        const HudEntry(tag: 'TX', text: 'Transmitting via flashlight...'),
      ];
    });

    try {
      await _modemChannel.invokeMethod('transmit', {'signal': signal});
    } catch (e) {
      debugPrint('  ⚠ Transmit error: $e');
    }

    // Step 4: Append the sent message and update HUD to "done".
    setState(() {
      _messages.add(Message.sent(text));
      _hudEntries = [
        const HudEntry(tag: 'UTF8', text: 'Binary conversion complete'),
        const HudEntry(tag: 'RS', text: 'Parity symbols appended'),
        const HudEntry(tag: '4PPM', text: 'Modulation complete'),
        const HudEntry(tag: 'TX', text: 'Transmission complete ✓'),
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
