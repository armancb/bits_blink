import 'dart:async';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/decoder_service.dart';
import '../theme/app_colors.dart';
import 'chat_screen.dart';

/// Live modem debugger — frame-level OOK with bits-to-text decode.
class DebugCaptureScreen extends StatefulWidget {
  const DebugCaptureScreen({super.key});

  @override
  State<DebugCaptureScreen> createState() => _DebugCaptureScreenState();
}

class _DebugCaptureScreenState extends State<DebugCaptureScreen> {
  static const _channel = MethodChannel('com.bitsblink/hardware');
  static const _streamChannel = EventChannel('com.bitsblink/debug_stream');

  Uint8List? _imageBytes;
  bool _isStreaming = false;
  String? _error;
  int _frameCount = 0;
  StreamSubscription? _streamSub;

  // ── Tracking ──
  bool _roiLocked = false;

  // ── Frame-level OOK ──
  /// Per-frame ROI brightness (no auto-deletion).
  final List<int> _frameBrightness = [];

  /// Binarized: one bit per frame (no auto-deletion).
  final List<bool> _frameBits = [];

  /// Adaptive threshold for frame classification.
  int _frameLevelThreshold = 128;
  int _recentMin = 255;
  int _recentMax = 0;

  DecodeResult? _lastDecode;

  // ── Feed log ──
  final List<String> _bitFeedLog = [];
  final ScrollController _feedScrollController = ScrollController();

  Future<void> _startStream() async {
    setState(() {
      _error = null;
      _frameCount = 0;
      // NO clearing of _frameBrightness, _frameBits, _bitFeedLog!
      // User explicitly requested no auto-deletion.
      _lastDecode = null;
      _recentMin = 255;
      _recentMax = 0;
      _frameLevelThreshold = 128;
    });

    try {
      _streamSub = _streamChannel.receiveBroadcastStream().listen(
        (dynamic data) {
          if (!mounted || data is! Map) return;

          final jpeg = data['jpeg'];
          final locked = data['locked'] as bool? ?? false;
          final roiAvg = data['roiAvg'] as int? ?? 0;

          // ── Frame-level OOK ──
          _frameBrightness.add(roiAvg);

          if (roiAvg < _recentMin) _recentMin = roiAvg;
          if (roiAvg > _recentMax) _recentMax = roiAvg;
          _frameLevelThreshold = (_recentMin + _recentMax) ~/ 2;

          // Slowly adapt
          if (_frameCount % 30 == 0 && _frameCount > 0) {
            _recentMin = (_recentMin + _frameLevelThreshold) ~/ 2;
            _recentMax = (_recentMax + _frameLevelThreshold) ~/ 2;
          }

          final bool isBright = roiAvg > _frameLevelThreshold;
          _frameBits.add(isBright);

          // Feed log
          _bitFeedLog.add(
            'F${_frameCount + 1} avg=$roiAvg thr=$_frameLevelThreshold → ${isBright ? "1" : "0"}',
          );

          // ── Decode accumulated bitstream ──
          DecodeResult? decodeResult;
          if (_frameBits.length >= 32) {
            decodeResult = DecoderService.decode(_frameBits);
          }

          setState(() {
            if (jpeg is Uint8List) {
              _imageBytes = jpeg;
            } else if (jpeg is List<int>) {
              _imageBytes = Uint8List.fromList(jpeg);
            }
            _frameCount++;
            _roiLocked = locked;
            _lastDecode = decodeResult;
          });

          // Auto-scroll
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_feedScrollController.hasClients) {
              _feedScrollController.jumpTo(
                _feedScrollController.position.maxScrollExtent,
              );
            }
          });
        },
        onError: (dynamic error) {
          if (mounted)
            setState(() {
              _error = error.toString();
              _isStreaming = false;
            });
        },
      );

      await _channel.invokeMethod('startDebugStream');
      if (mounted) setState(() => _isStreaming = true);
    } on PlatformException catch (e) {
      _streamSub?.cancel();
      _streamSub = null;
      if (mounted)
        setState(() {
          _error = e.message ?? 'Failed';
          _isStreaming = false;
        });
    }
  }

  Future<void> _stopStream() async {
    try {
      await _channel.invokeMethod('stopDebugStream');
    } catch (_) {}
    _streamSub?.cancel();
    _streamSub = null;
    if (mounted) setState(() => _isStreaming = false);
  }

  void _clearData() {
    setState(() {
      _frameBrightness.clear();
      _frameBits.clear();
      _bitFeedLog.clear();
      _lastDecode = null;
      _frameCount = 0;
    });
  }

  @override
  void dispose() {
    _stopStream();
    _feedScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          'MODEM RECEIVER',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.0,
            color: AppColors.primary,
          ),
        ),
        backgroundColor: Colors.white,
        iconTheme: const IconThemeData(color: AppColors.primary),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(
              Icons.send_to_mobile,
              size: 20,
              color: AppColors.primary,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ChatScreen()),
              );
            },
            tooltip: 'Open Transmitter',
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_outline,
              size: 20,
              color: Colors.black54,
            ),
            onPressed: _clearData,
            tooltip: 'Clear data',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _buildControlBar(),
          Expanded(
            child: _error != null
                ? _buildError()
                : _imageBytes != null
                ? _buildMainView()
                : _buildEmptyState(),
          ),
        ],
      ),
    );
  }

  Widget _buildControlBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 36,
              child: ElevatedButton.icon(
                onPressed: _isStreaming ? _stopStream : _startStream,
                icon: Icon(
                  _isStreaming ? Icons.pause : Icons.play_arrow,
                  size: 16,
                ),
                label: Text(
                  _isStreaming ? 'PAUSE' : 'START',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                    fontSize: 11,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isStreaming
                      ? Colors.orange.shade700
                      : AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _buildTag(
            _roiLocked ? Icons.lock : Icons.lock_open,
            _roiLocked ? Colors.greenAccent : Colors.orangeAccent,
            _roiLocked ? 'LOCK' : 'SCAN',
          ),
          const SizedBox(width: 4),
          _buildTag(Icons.memory, Colors.cyanAccent, '${_frameBits.length}f'),
          if (_lastDecode != null) ...[
            const SizedBox(width: 4),
            _buildTag(
              Icons.speed,
              Colors.black54,
              '${_lastDecode!.chipWidth}f/c',
              bg: const Color(0xFFEEEEEE),
            ),
            if (_lastDecode!.preambleFound) ...[
              const SizedBox(width: 4),
              _buildTag(
                Icons.check,
                Colors.green.shade700,
                'PRE',
                bg: Colors.green.shade50,
              ),
            ],
            if (_lastDecode!.syncFound) ...[
              const SizedBox(width: 4),
              _buildTag(
                Icons.sync,
                Colors.blue.shade700,
                'SYNC',
                bg: Colors.blue.shade50,
              ),
            ],
            if (_lastDecode!.rsSuccess) ...[
              const SizedBox(width: 4),
              _buildTag(
                Icons.shield,
                Colors.green.shade700,
                'RS✓',
                bg: Colors.green.shade50,
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildTag(IconData icon, Color color, String label, {Color? bg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: bg ?? const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.black.withOpacity(0.05)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 10),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'monospace',
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainView() {
    return Column(
      children: [
        // ── Camera preview ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.memory(
                _imageBytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),

        // ── OOK Chart: frame brightness over time ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Container(
            height: 50,
            decoration: BoxDecoration(
              color: const Color(0xFFF5F7FA),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.black.withOpacity(0.05)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: CustomPaint(
                size: const Size(double.infinity, 50),
                painter: _OOKPainter(
                  values: _frameBrightness,
                  threshold: _frameLevelThreshold,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),

        // ── Decode result (including bits→text widget) ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _buildDecodePanel(),
        ),
        const SizedBox(height: 4),

        // ── Scrolling bit feed ──
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _buildBitFeed(),
          ),
        ),

        // ── Accumulated bits bar ──
        _buildAccumulatedBar(),
      ],
    );
  }

  /// Main decode panel: shows status, resampled bits, and decoded text.
  Widget _buildDecodePanel() {
    final result = _lastDecode;

    if (result == null || result.isNoSignal) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.black.withOpacity(0.05)),
        ),
        child: Row(
          children: [
            const Icon(Icons.sensors, color: Colors.black26, size: 12),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                result?.error ?? 'Waiting for data…',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: Colors.black45,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // ── Decoded successfully ──
    if (result.success) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          border: Border.all(color: Colors.green.shade200),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.check_circle,
                  color: Colors.green.shade700,
                  size: 14,
                ),
                const SizedBox(width: 6),
                Text(
                  'DECODED',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.green.shade700,
                    letterSpacing: 1.5,
                  ),
                ),
                const Spacer(),
                Text(
                  '${result.chipWidth}f/c',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: Colors.black38,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.black.withOpacity(0.05)),
              ),
              child: Text(
                result.decodedText!,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.green.shade800,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${result.dataLength ?? 0} bytes | Preamble: ✓ | Sync: ${result.syncFound ? "✓" : "✗"}',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 4),
            // ── Bits to text: show the raw resampled bit string ──
            _buildBitsToTextWidget(result),
          ],
        ),
      );
    }

    // ── Partial progress ──
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: result.preambleFound ? Colors.orange.shade50 : Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: result.preambleFound
              ? Colors.orange.shade200
              : Colors.black.withOpacity(0.05),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                result.preambleFound ? Icons.sync : Icons.sensors,
                color: result.preambleFound
                    ? Colors.orange.shade700
                    : Colors.black26,
                size: 12,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  result.error ?? 'Processing…',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: result.preambleFound
                        ? Colors.orange.shade800
                        : Colors.black45,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${result.chipWidth}f/c',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: Colors.black26,
                ),
              ),
            ],
          ),
          if ((result.resampledBits ?? '').isNotEmpty &&
              result.resampledBits!.length < 300) ...[
            const SizedBox(height: 4),
            _buildBitsToTextWidget(result),
          ],
        ],
      ),
    );
  }

  /// Shows the resampled bits grouped into bytes with live text decode.
  Widget _buildBitsToTextWidget(DecodeResult result) {
    final bits = result.resampledBits ?? '';
    if (bits.isEmpty) return const SizedBox.shrink();

    // Group into bytes and try to decode each
    final byteStrings = <String>[];
    final charResults = <String>[];
    for (int i = 0; i + 7 < bits.length; i += 8) {
      final byteBits = bits.substring(i, i + 8);
      byteStrings.add(byteBits);
      int val = 0;
      for (int j = 0; j < 8; j++) {
        if (byteBits[j] == '1') val |= (1 << (7 - j));
      }
      charResults.add(val >= 32 && val < 127 ? String.fromCharCode(val) : '·');
    }

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FA),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.black.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'BITS → TEXT',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 8,
              fontWeight: FontWeight.w700,
              color: Colors.black38,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 3),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: List.generate(min(byteStrings.length, 30), (i) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    byteStrings[i],
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 8,
                      color: charResults[i] != '·'
                          ? AppColors.primary
                          : Colors.black26,
                    ),
                  ),
                  Text(
                    charResults[i],
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: charResults[i] != '·'
                          ? AppColors.primary
                          : Colors.black26,
                    ),
                  ),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildBitFeed() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.black.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 5, 8, 2),
            child: Text(
              'FRAME OOK FEED (${_bitFeedLog.length} entries)',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 8,
                fontWeight: FontWeight.w700,
                color: Colors.black38,
                letterSpacing: 1.5,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _feedScrollController,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              itemCount: _bitFeedLog.length,
              itemBuilder: (ctx, i) {
                final line = _bitFeedLog[i];
                final isBright = line.endsWith('1');
                return Padding(
                  padding: const EdgeInsets.only(bottom: 0),
                  child: Text(
                    line,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 9,
                      color: isBright ? Colors.green.shade700 : Colors.black26,
                      fontWeight: isBright ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccumulatedBar() {
    final tailLen = min(300, _frameBits.length);
    final tail = _frameBits.sublist(_frameBits.length - tailLen);
    return Container(
      height: 16,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      decoration: BoxDecoration(
        color: const Color(0xFFEEEEEE),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: Colors.black.withOpacity(0.05)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Row(
          children: tail
              .map(
                (b) => Expanded(
                  child: Container(
                    color: b ? const Color(0xFF4CAF50) : Colors.transparent,
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
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

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sensors, color: Colors.black.withOpacity(0.05), size: 64),
          const SizedBox(height: 12),
          Text(
            'Tap START to begin\noptical modem debug',
            style: TextStyle(
              color: Colors.black.withOpacity(0.3),
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

class _OOKPainter extends CustomPainter {
  final List<int> values;
  final int threshold;
  _OOKPainter({required this.values, required this.threshold});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final int maxVisible = size.width.toInt();
    final int startIdx = max(0, values.length - maxVisible);
    final int count = values.length - startIdx;
    final double barWidth = size.width / count;
    final paint = Paint();

    for (int i = 0; i < count; i++) {
      final v = values[startIdx + i].clamp(0, 255);
      final barH = (v / 255.0) * size.height;
      paint.color = v > threshold
          ? const Color(0xFF4CAF50)
          : const Color(0xFF1E1E1E);
      canvas.drawRect(
        Rect.fromLTWH(i * barWidth, size.height - barH, barWidth + 0.5, barH),
        paint,
      );
    }

    final threshY =
        size.height - (threshold.clamp(0, 255) / 255.0) * size.height;
    canvas.drawLine(
      Offset(0, threshY),
      Offset(size.width, threshY),
      Paint()
        ..color = const Color(0xFFFF5252)
        ..strokeWidth = 1.0,
    );
  }

  @override
  bool shouldRepaint(covariant _OOKPainter old) => true;
}
