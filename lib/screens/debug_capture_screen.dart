import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/dsp_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import 'chat_screen.dart';

/// Receiver home screen — oscilloscope + decoded message display.
///
/// Light-themed to match the transmitter UI. Camera stays open between
/// SFD and EFD sync words for continuous frame capture and decoding.
class DebugCaptureScreen extends StatefulWidget {
  const DebugCaptureScreen({super.key});

  @override
  State<DebugCaptureScreen> createState() => _DebugCaptureScreenState();
}

class _DebugCaptureScreenState extends State<DebugCaptureScreen> {
  static const _streamChannel = EventChannel('com.bitsblink/stream');

  StreamSubscription? _subscription;
  List<double> _intensities = [];
  List<int> _bits = [];
  bool _streaming = false;
  String? _error;
  int _frameCount = 0;

  // ── DSP Receiver ──
  late DSPService _dspService;
  final List<String> _decodedMessages = [];
  String? _rxStatus;

  @override
  void initState() {
    super.initState();
    _initDspService();
  }

  void _initDspService() {
    _dspService = DSPService(
      onPreambleFound: (index) {
        if (!mounted) return;
        setState(() => _rxStatus = '🚨 SFD LOCKED @ chip $index');
      },
      onPacketDecoded: (text) {
        if (!mounted) return;
        setState(() {
          _decodedMessages.add(text);
          _rxStatus = '✅ DECODED: "$text"';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Decoded: "$text"'),
            backgroundColor: AppColors.primary,
            duration: const Duration(seconds: 3),
          ),
        );
      },
      onError: (msg) {
        if (!mounted) return;
        setState(() => _rxStatus = '❌ $msg');
      },
    );
  }

  @override
  void dispose() {
    _stopStream();
    super.dispose();
  }

  void _startStream() {
    setState(() {
      _streaming = true;
      _error = null;
      _frameCount = 0;
      _rxStatus = null;
    });
    _dspService.reset();

    _subscription = _streamChannel.receiveBroadcastStream().listen(
      (data) {
        if (!mounted) return;

        final map = Map<String, dynamic>.from(data as Map);
        final intensities = List<double>.from(
          (map['intensities'] as List).map((e) => (e as num).toDouble()),
        );
        final bits = List<int>.from(map['bits'] as List);

        // Build a compact bit string for DSP
        final bitStr = bits.join();

        // ── ALWAYS feed DSPService (signal processing runs at full speed) ──
        _dspService.feedFrame(bitStr);

        _frameCount++;

        // ── Throttle UI: only update the waveform every 5th frame ──
        if (_frameCount % 5 == 0 || _frameCount == 1) {
          setState(() {
            _intensities = intensities;
            _bits = bits;
          });
        } else {
          setState(() {
            _intensities = intensities;
            _bits = bits;
          });
        }
      },
      onError: (Object error) {
        if (mounted) {
          setState(() {
            _error = error.toString();
            _streaming = false;
          });
        }
      },
      onDone: () {
        if (mounted) setState(() => _streaming = false);
      },
    );
  }

  void _stopStream() {
    _subscription?.cancel();
    _subscription = null;
    _dspService.reset();
    if (mounted) setState(() => _streaming = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      body: Column(
        children: [
          // ── Header ──
          _buildHeader(context),

          // ── Start / Stop button ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _streaming ? _stopStream : _startStream,
                icon: Icon(
                  _streaming ? Icons.stop_rounded : Icons.sensors_rounded,
                  size: 22,
                ),
                label: Text(
                  _streaming ? 'STOP RECEIVER' : 'START RECEIVER',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    fontSize: 14,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _streaming ? Colors.red.shade400 : AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: _streaming ? 0 : 2,
                ),
              ),
            ),
          ),

          // ── Live content ──
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
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
                  'OPTICAL MODEM RECEIVER',
                  style: AppTextStyles.headerSubtitle,
                ),
              ],
            ),

            // ── Navigate to Transmitter ──
            TextButton.icon(
              icon:
                  const Icon(Icons.send_rounded, size: 18, color: AppColors.primary),
              label: const Text(
                'Transmit',
                style: TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ChatScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: Colors.red.shade400, size: 48),
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Colors.red.shade400, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (_intensities.isNotEmpty) {
      return Column(
        children: [
          // ── Info bar ──
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 20),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.inputBackground,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _streaming
                      ? Icons.fiber_manual_record
                      : Icons.check_circle,
                  color:
                      _streaming ? Colors.red.shade400 : AppColors.statusOnline,
                  size: 12,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_streaming ? "LIVE" : "STOPPED"}  •  '
                    'F#$_frameCount  •  '
                    '${_intensities.length} rows',
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

          // ── Oscilloscope Waveform ──
          Container(
            height: 200,
            margin: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: const Color(0xFF0A0E14),
              border: Border.all(
                color: Colors.grey.shade300,
                width: 1,
              ),
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(12),
              ),
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(11),
              ),
              child: CustomPaint(
                painter: WaveformPainter(
                  intensities: _intensities,
                  bits: _bits,
                ),
                size: Size.infinite,
              ),
            ),
          ),

          const SizedBox(height: 12),

          // ── RX Pipeline Status ──
          if (_rxStatus != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: _rxStatus!.startsWith('✅')
                    ? Colors.green.shade50
                    : _rxStatus!.startsWith('❌')
                        ? Colors.red.shade50
                        : Colors.orange.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _rxStatus!.startsWith('✅')
                      ? Colors.green.shade200
                      : _rxStatus!.startsWith('❌')
                          ? Colors.red.shade200
                          : Colors.orange.shade200,
                ),
              ),
              child: Text(
                _rxStatus!,
                style: TextStyle(
                  color: _rxStatus!.startsWith('✅')
                      ? Colors.green.shade700
                      : _rxStatus!.startsWith('❌')
                          ? Colors.red.shade700
                          : Colors.orange.shade700,
                  fontSize: 13,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

          const SizedBox(height: 8),

          // ── Decoded Messages ──
          Expanded(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              decoration: BoxDecoration(
                color: AppColors.inputBackground,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.inputBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title bar
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.scaffoldBackground,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(12),
                      ),
                      border: Border(
                        bottom: BorderSide(color: AppColors.inputBorder),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.message_rounded,
                          color: AppColors.primary,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'RECEIVED MESSAGES',
                          style: TextStyle(
                            color: AppColors.primaryDark,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const Spacer(),
                        if (_decodedMessages.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${_decodedMessages.length}',
                              style: TextStyle(
                                color: AppColors.primary,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  // Messages list
                  Expanded(
                    child: _decodedMessages.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.inbox_rounded,
                                  color: Colors.grey.shade300,
                                  size: 40,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'No messages received yet',
                                  style: TextStyle(
                                    color: Colors.grey.shade400,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: _decodedMessages.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: Colors.grey.shade200,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.04),
                                      blurRadius: 4,
                                      offset: const Offset(0, 1),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      Icons.arrow_downward_rounded,
                                      color: AppColors.primary,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        _decodedMessages[index],
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w500,
                                          color: AppColors.textOnReceived,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // ── Empty state ──
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.sensors_rounded,
            color: Colors.grey.shade300,
            size: 64,
          ),
          const SizedBox(height: 12),
          Text(
            'Tap START RECEIVER to begin\nlistening for optical signals',
            style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Oscilloscope CustomPainter
// ═══════════════════════════════════════════════════════════════════════

/// Draws a real-time oscilloscope view:
/// - **Green line** (2px): Analog brightness waveform (intensities 0-255)
/// - **Red line** (1px, 50% opacity): Digital square wave (bits 0/1)
class WaveformPainter extends CustomPainter {
  final List<double> intensities;
  final List<int> bits;

  WaveformPainter({required this.intensities, required this.bits});

  @override
  void paint(Canvas canvas, Size size) {
    if (intensities.isEmpty) return;

    final w = size.width;
    final h = size.height;

    // ── Draw grid lines (subtle) ──
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 0.5;

    for (int i = 1; i < 4; i++) {
      final y = h * i / 4;
      canvas.drawLine(Offset(0, y), Offset(w, y), gridPaint);
    }

    // ── Digital wave (red, background) ──
    if (bits.isNotEmpty) {
      final digitalPaint = Paint()
        ..color = Colors.redAccent.withValues(alpha: 0.4)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;

      final digitalPath = ui.Path();
      final dxStep = w / bits.length;
      const highY = 0.1; // 10% from top
      const lowY = 0.9; // 90% from top

      for (int i = 0; i < bits.length; i++) {
        final x = i * dxStep;
        final y = bits[i] == 1 ? h * highY : h * lowY;

        if (i == 0) {
          digitalPath.moveTo(x, y);
        } else {
          // Square wave: draw horizontal then vertical
          final prevY = bits[i - 1] == 1 ? h * highY : h * lowY;
          if (y != prevY) {
            digitalPath.lineTo(x, prevY); // horizontal to transition point
            digitalPath.lineTo(x, y); // vertical jump
          } else {
            digitalPath.lineTo(x, y);
          }
        }
      }
      canvas.drawPath(digitalPath, digitalPaint);
    }

    // ── Analog wave (green, foreground) ──
    final analogPaint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    final analogPath = ui.Path();
    final dxStep = w / intensities.length;

    for (int i = 0; i < intensities.length; i++) {
      final x = i * dxStep;
      // Map 255 → top (y=0), 0 → bottom (y=h)
      final y = h - (intensities[i] / 255.0) * h;

      if (i == 0) {
        analogPath.moveTo(x, y);
      } else {
        analogPath.lineTo(x, y);
      }
    }
    canvas.drawPath(analogPath, analogPaint);

    // ── Axis labels ──
    _drawLabel(canvas, '255', 4, 12);
    _drawLabel(canvas, '128', 4, h / 2 - 4);
    _drawLabel(canvas, '0', 4, h - 16);
  }

  void _drawLabel(Canvas canvas, String text, double x, double y) {
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(textAlign: TextAlign.left, fontSize: 9),
          )
          ..pushStyle(
            ui.TextStyle(
              color: Colors.white.withValues(alpha: 0.3),
              fontFamily: 'monospace',
            ),
          )
          ..addText(text);
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: 30));
    canvas.drawParagraph(paragraph, Offset(x, y));
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.intensities != intensities || oldDelegate.bits != bits;
  }
}
