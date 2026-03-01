import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/dsp_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// High-speed oscilloscope debug screen for the optical modem receiver.
///
/// Receives raw `intensities` (row brightness 0-255) and `bits` (1s/0s)
/// from the native headless pipeline, visualises them as a waveform, and
/// feeds every frame into [DSPService] for decoding.
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

  // Scrollable log of received bit strings
  final List<String> _bitLog = [];
  final _logScrollController = ScrollController();

  // ── DSP Receiver ──
  late DSPService _dspService;
  String? _decodedMessage;
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
        setState(() => _rxStatus = '🚨 PREAMBLE LOCKED @ chip $index');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🚨 BINGO! Preamble locked at chip $index'),
            backgroundColor: Colors.orange.shade800,
            duration: const Duration(seconds: 2),
          ),
        );
      },
      onPacketDecoded: (text) {
        if (!mounted) return;
        setState(() {
          _decodedMessage = text;
          _rxStatus = '✅ DECODED: "$text"';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Decoded: "$text"'),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 4),
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
    _logScrollController.dispose();
    super.dispose();
  }

  void _startStream() {
    setState(() {
      _streaming = true;
      _error = null;
      _frameCount = 0;
      _bitLog.clear();
      _decodedMessage = null;
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

        // Build a compact bit string for the log
        final bitStr = bits.join();

        // ── ALWAYS feed DSPService (signal processing runs at full speed) ──
        _dspService.feedFrame(bitStr);

        _frameCount++;

        // ── Throttle UI: only update the waveform + log every 5th frame ──
        if (_frameCount % 5 == 0 || _frameCount == 1) {
          setState(() {
            _intensities = intensities;
            _bits = bits;
            _bitLog.add('#$_frameCount  $bitStr');
            if (_bitLog.length > 100) _bitLog.removeAt(0);
          });

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_logScrollController.hasClients) {
              _logScrollController.jumpTo(
                _logScrollController.position.maxScrollExtent,
              );
            }
          });
        } else {
          // Still update the waveform (cheap repaint) but skip log rebuild
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
      backgroundColor: AppColors.hudBackground,
      appBar: AppBar(
        title: const Text(
          'OSCILLOSCOPE',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.0,
            color: Colors.white70,
          ),
        ),
        backgroundColor: AppColors.hudBackground,
        iconTheme: const IconThemeData(color: Colors.white70),
        elevation: 0,
      ),
      body: Column(
        children: [
          // ── Start / Stop button ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                onPressed: _streaming ? _stopStream : _startStream,
                icon: Icon(
                  _streaming ? Icons.stop : Icons.play_arrow,
                  size: 20,
                ),
                label: Text(
                  _streaming ? 'STOP STREAM' : 'START STREAM',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _streaming
                      ? Colors.redAccent
                      : AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
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

  Widget _buildContent() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 48,
              ),
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 14),
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
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _streaming ? Icons.fiber_manual_record : Icons.check_circle,
                  color: _streaming ? Colors.redAccent : AppColors.hudAccent,
                  size: 14,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_streaming ? "LIVE" : "STOPPED"}  •  '
                    'F#$_frameCount  •  '
                    '${_intensities.length} rows  •  '
                    '${_bits.length} bits',
                    style: AppTextStyles.hudLog,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

          // ── Oscilloscope Waveform ──
          Container(
            height: 250,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF0A0E14),
              border: Border.all(
                color: Colors.greenAccent.withValues(alpha: 0.3),
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: CustomPaint(
                painter: WaveformPainter(
                  intensities: _intensities,
                  bits: _bits,
                ),
                size: Size.infinite,
              ),
            ),
          ),

          const SizedBox(height: 4),

          // ── RX Pipeline Status ──
          if (_rxStatus != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _decodedMessage != null
                    ? Colors.green.withValues(alpha: 0.15)
                    : Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _decodedMessage != null
                      ? Colors.green.withValues(alpha: 0.4)
                      : Colors.orange.withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                _rxStatus!,
                style: TextStyle(
                  color: _decodedMessage != null
                      ? Colors.greenAccent
                      : Colors.orangeAccent,
                  fontSize: 12,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

          // ── Decoded Message Card ──
          if (_decodedMessage != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.green.withValues(alpha: 0.2),
                    Colors.teal.withValues(alpha: 0.1),
                  ],
                ),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.greenAccent.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    color: Colors.greenAccent,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _decodedMessage!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ── Binary data scrolling log ──
          Expanded(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0E14),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.terminal,
                        color: Colors.greenAccent,
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'DEMODULATED BITS',
                        style: TextStyle(
                          color: Colors.greenAccent.withValues(alpha: 0.8),
                          fontSize: 11,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Divider(
                    color: Colors.white.withValues(alpha: 0.1),
                    height: 1,
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: ListView.builder(
                      controller: _logScrollController,
                      itemCount: _bitLog.length,
                      itemBuilder: (context, index) {
                        return Text(
                          _bitLog[index],
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 10,
                            fontFamily: 'monospace',
                            height: 1.4,
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
            Icons.show_chart,
            color: Colors.white.withValues(alpha: 0.15),
            size: 64,
          ),
          const SizedBox(height: 12),
          Text(
            'Tap START STREAM to begin\nheadless oscilloscope feed',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.3),
              fontSize: 14,
              fontFamily: 'monospace',
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
