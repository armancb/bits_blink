import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// Debug screen that captures a single camera frame, extracts the Y-plane,
/// highlights the brightest ROI, and displays the resulting image.
class DebugCaptureScreen extends StatefulWidget {
  const DebugCaptureScreen({super.key});

  @override
  State<DebugCaptureScreen> createState() => _DebugCaptureScreenState();
}

class _DebugCaptureScreenState extends State<DebugCaptureScreen> {
  static const _channel = MethodChannel('com.bitsblink/hardware');

  Uint8List? _imageBytes;
  bool _loading = false;
  String? _error;

  Future<void> _captureFrame() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await _channel.invokeMethod<Uint8List>(
        'captureDebugFrame',
      );
      setState(() {
        _imageBytes = result;
        _loading = false;
      });
    } on PlatformException catch (e) {
      setState(() {
        _error = e.message ?? 'Capture failed';
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.hudBackground,
      appBar: AppBar(
        title: const Text(
          'DEBUG CAPTURE',
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
          // ── Capture button ──
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _captureFrame,
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.camera_alt, size: 20),
                label: Text(
                  _loading ? 'CAPTURING...' : 'CAPTURE FRAME',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),

          // ── Image / status area ──
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

    if (_imageBytes != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ── Info bar ──
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(8),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.check_circle,
                    color: AppColors.hudAccent,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Y-PLANE  •  ROI  •  ${(_imageBytes!.length / 1024).toStringAsFixed(1)} KB',
                      style: AppTextStyles.hudLog,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),

            // ── Image ──
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(8),
                ),
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 5.0,
                  child: Image.memory(
                    _imageBytes!,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // ── Empty state ──
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.videocam_outlined,
            color: Colors.white.withOpacity(0.15),
            size: 64,
          ),
          const SizedBox(height: 12),
          Text(
            'Tap CAPTURE FRAME to grab a\nY-Plane debug image',
            style: TextStyle(
              color: Colors.white.withOpacity(0.3),
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
