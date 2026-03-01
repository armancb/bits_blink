import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../reed_solomon/galois_field.dart';
import '../reed_solomon/reed_solomon.dart';

/// Receiver state machine phases.
enum _RxState { hunting, locked, receiving }

/// DSP (Digital Signal Processing) Service for the 4-PPM optical modem
/// receiver pipeline, based on the U-Flash adaptive threshold architecture
/// (ACM 10.1145/3699769).
///
/// This is a **stateful** service: call [feedFrame] with every raw bitstring
/// from the native EventChannel, and it will accumulate data across frames,
/// downsample, hunt for the preamble, demodulate 4-PPM symbols, RS-decode,
/// and fire callbacks when a packet is fully recovered.
class DSPService {
  // ── Protocol constants ──────────────────────────────────────────────

  /// Camera rows per flash slot (oversampling factor).
  /// Auto-calibrated from first frame if set to 0.
  /// Formula: (chipDurationMs / frameDurationMs) × imageHeight
  int samplesPerSlot;

  /// 4-PPM chip representation of the 0xAA (10101010) preamble byte.
  /// Each di-bit pair (10) maps to chip pattern 0010, repeated 4 times.
  static const String preambleChips = '0010001000100010';

  /// Reverse look-up: position of the '1' in a 4-chip symbol → di-bit.
  static const List<String> _ppmDecode = ['00', '01', '10', '11'];

  // ── Callbacks ───────────────────────────────────────────────────────

  /// Fired when the preamble is first detected.
  final void Function(int chipIndex)? onPreambleFound;

  /// Fired when a complete packet has been RS-decoded to UTF-8 text.
  final void Function(String decodedText)? onPacketDecoded;

  /// Fired when an unrecoverable error occurs (RS failure, etc.).
  final void Function(String message)? onError;

  /// Fired on every frame with the current compressed chip string (for
  /// debug display).
  final void Function(String chips)? onChipsUpdated;

  // ── Internal state ──────────────────────────────────────────────────

  final StringBuffer _chipAccumulator = StringBuffer();
  _RxState _state = _RxState.hunting;
  int _preambleIndex = -1;
  int _payloadLength = -1; // data bytes (from the length header)
  bool _rsTablesReady = false;

  // Carry-over state for cross-frame boundary runs.
  String _lastChar = '';
  int _pendingRunLength = 0;

  DSPService({
    this.samplesPerSlot = 0, // 0 = auto-calibrate from first frame
    this.onPreambleFound,
    this.onPacketDecoded,
    this.onError,
    this.onChipsUpdated,
  });

  // ── Public API ──────────────────────────────────────────────────────

  /// Feed one frame's worth of raw oversampled bits (e.g. 480 chars of
  /// '1's and '0's) from the native camera pipeline.
  ///
  /// Each frame is downsampled individually (~34 chips) and the chips
  /// are appended to an internal accumulator to avoid O(n²) growth.
  /// Diagnostic: count frames for periodic logging.
  int _feedFrameCount = 0;

  void feedFrame(String rawBits) {
    // Auto-calibrate samplesPerSlot from actual camera row count.
    // The transmitter is sending 15ms chips.
    if (samplesPerSlot == 0 && rawBits.isNotEmpty) {
      const targetChipMs = 15.0;
      const frameMs = 33.0;
      samplesPerSlot = (targetChipMs / frameMs * rawBits.length).round();
      debugPrint(
        '📐 Auto-calibrated samplesPerSlot = $samplesPerSlot '
        '(${rawBits.length} rows, ${targetChipMs}ms target chips)',
      );
    }

    // ── Debug: Log signal frames + periodic heartbeat ──
    _feedFrameCount++;
    final bool hasSignal = rawBits.contains('1');
    final bool isHeartbeat = _feedFrameCount % 30 == 1;
    final bool shouldLog = hasSignal || isHeartbeat;

    if (shouldLog && rawBits.isNotEmpty) {
      // Compute RLE of the raw bit string to see actual run lengths
      final runs = <String>[];
      int runStart = 0;
      for (int i = 1; i <= rawBits.length; i++) {
        if (i == rawBits.length || rawBits[i] != rawBits[runStart]) {
          runs.add('${rawBits[runStart]}×${i - runStart}');
          runStart = i;
        }
      }
      // Show first 10 runs to avoid flooding
      final preview = runs.take(10).join(', ');
      final tag = hasSignal ? '🔴 SIGNAL' : '📊';
      debugPrint(
        '$tag F#$_feedFrameCount raw RLE: $preview'
        '${runs.length > 10 ? " ... (${runs.length} total runs)" : ""}',
      );
    }

    // Skip all-zero frames: don't let silence accumulate as carry-over.
    // Without this, 35 silent frames = 68,000 zeros → 165 spurious '0' chips
    // when signal finally appears.
    final bool isAllZero = !rawBits.contains('1');
    if (isAllZero) {
      // Reset carry-over: silence is not data.
      if (_lastChar == '0') {
        _pendingRunLength = 0;
      }
    }

    final newChips = _downsampleFrame(rawBits);
    _chipAccumulator.write(newChips);

    if (shouldLog) {
      debugPrint(
        '📊 F#$_feedFrameCount → ${newChips.length} new chips, '
        'buf=${_chipAccumulator.length} total, '
        'samplesPerSlot=$samplesPerSlot, state=$_state',
      );
    }

    // Safety cap: prevent unbounded growth if no preamble is ever found.
    // 10 000 chips ≈ 300 frames ≈ enough for any reasonable packet.
    if (_state == _RxState.hunting && _chipAccumulator.length > 10000) {
      final str = _chipAccumulator.toString();
      _chipAccumulator.clear();
      // Keep only the last 2000 chips (sliding window).
      _chipAccumulator.write(str.substring(str.length - 2000));
    }

    // Build a "preview" chip string that includes the pending
    // (not-yet-flushed) run, so the state machine sees the full picture.
    final pendingPreview = _previewPendingRun();
    final chips = '${_chipAccumulator.toString()}$pendingPreview';
    onChipsUpdated?.call(chips);

    switch (_state) {
      case _RxState.hunting:
        _huntPreamble(chips);
      case _RxState.locked:
        // locked state is handled inside _huntPreamble (two-stage)
        _huntPreamble(chips);
      case _RxState.receiving:
        _collectPayload(chips);
    }
  }

  /// Reset the receiver state machine for a fresh capture.
  void reset() {
    _chipAccumulator.clear();
    _state = _RxState.hunting;
    _preambleIndex = -1;
    _payloadLength = -1;
    _lastChar = '';
    _pendingRunLength = 0;
    _triedPositions.clear();
  }

  // ── Step 1: Downsampling (RLE → chips), one frame at a time ─────────

  /// Downsample a single frame's raw bits into chips, carrying over
  /// any incomplete run from the previous frame so that flashes
  /// spanning frame boundaries are handled correctly.
  String _downsampleFrame(String rawBits) {
    if (rawBits.isEmpty) return '';

    final StringBuffer compressed = StringBuffer();

    for (int i = 0; i < rawBits.length; i++) {
      final c = rawBits[i];

      if (_lastChar.isEmpty) {
        // First character ever seen.
        _lastChar = c;
        _pendingRunLength = 1;
      } else if (c == _lastChar) {
        _pendingRunLength++;
      } else {
        // Character changed → emit the completed run.
        _emitRun(compressed, _lastChar, _pendingRunLength);
        _lastChar = c;
        _pendingRunLength = 1;
      }
    }

    // DO NOT flush the pending run here — it may continue into the
    // next frame. It will be flushed when the character changes or
    // when reset() is called.

    return compressed.toString();
  }

  /// Preview what the pending (not-yet-flushed) run would produce,
  /// WITHOUT resetting the carry-over state.
  String _previewPendingRun() {
    if (_pendingRunLength > 0 && _lastChar.isNotEmpty) {
      final buf = StringBuffer();
      _emitRun(buf, _lastChar, _pendingRunLength);
      return buf.toString();
    }
    return '';
  }

  /// Quantise one run into chip-rate slots and append to [buffer].
  void _emitRun(StringBuffer buffer, String char, int runLength) {
    int slots = (runLength / samplesPerSlot).round();

    // Guard: only force a slot for runs that are at least 40% of a chip.
    // This prevents noise bursts from becoming spurious chips.
    final minRunForChip = (samplesPerSlot * 0.4).round();
    if (runLength >= minRunForChip && slots == 0) {
      slots = 1;
    }

    for (int s = 0; s < slots; s++) {
      buffer.write(char);
    }
  }

  // ── Step 2: Preamble hunting (correlation-based fuzzy match) ────────

  /// Stage 1 threshold: 75% = 12/16 chips match.
  /// Stage 2 validates by checking the length header for sanity.
  static const double _preambleThreshold = 0.75;

  /// Positions already tried and rejected (false positives).
  final Set<int> _triedPositions = {};

  void _huntPreamble(String chips) {
    if (chips.length < preambleChips.length + 16)
      return; // need room for header

    int bestIdx = -1;
    double bestScore = 0.0;
    int bestWindowLen = preambleChips.length;

    // Slide the preamble template over the chip buffer.
    for (int i = 0; i <= chips.length - preambleChips.length - 16; i++) {
      if (_triedPositions.contains(i)) continue; // already rejected

      int matches = 0;
      int onesMatched = 0;
      for (int j = 0; j < preambleChips.length; j++) {
        if (chips[i + j] == preambleChips[j]) {
          matches++;
          if (preambleChips[j] == '1') onesMatched++;
        }
      }
      final score = matches / preambleChips.length;
      // Require at least 3 matching '1's (prevents solid zero blocks from scoring 75%)
      if (score > bestScore && onesMatched >= 3) {
        bestScore = score;
        bestIdx = i;
        bestWindowLen = preambleChips.length;
      }
    }

    // Also try slightly stretched/compressed preamble windows (±2 chips)
    // to handle rolling shutter jitter that adds or removes chips.
    for (int stretch = -2; stretch <= 2; stretch++) {
      if (stretch == 0) continue; // already checked
      final windowLen = preambleChips.length + stretch;
      if (windowLen < 8 || chips.length < windowLen + 16) continue;

      for (int i = 0; i <= chips.length - windowLen - 16; i++) {
        if (_triedPositions.contains(i)) continue;

        // Map the window back to the 16-chip template using nearest-neighbor
        int matches = 0;
        int onesMatched = 0;
        for (int j = 0; j < preambleChips.length; j++) {
          final mappedIdx = i + (j * windowLen / preambleChips.length).round();
          if (mappedIdx < chips.length &&
              chips[mappedIdx] == preambleChips[j]) {
            matches++;
            if (preambleChips[j] == '1') onesMatched++;
          }
        }
        final score = matches / preambleChips.length;
        if (score > bestScore && onesMatched >= 3) {
          bestScore = score;
          bestIdx = i;
          bestWindowLen = windowLen;
        }
      }
    }

    if (bestScore < _preambleThreshold) {
      // Log best score periodically for debugging
      if (_feedFrameCount % 30 == 0 && bestScore > 0.3) {
        debugPrint(
          '🔍 Best preamble score: ${(bestScore * 100).toInt()}% '
          'at idx $bestIdx (need ${(_preambleThreshold * 100).toInt()}%)',
        );
      }
      return;
    }

    // ── Stage 2: Validate by checking the length header ──
    final headerStart = bestIdx + bestWindowLen;
    if (chips.length < headerStart + 16) return;

    final headerChips = chips.substring(headerStart, headerStart + 16);
    final headerBytes = _demodulateChips(headerChips);
    if (headerBytes == null || headerBytes.isEmpty) {
      debugPrint(
        '🔍 Preamble at idx $bestIdx (${(bestScore * 100).toInt()}%) '
        '→ header demod failed, skipping',
      );
      _triedPositions.add(bestIdx);
      return;
    }

    final candidateLength = headerBytes[0];
    if (candidateLength <= 0 || candidateLength > 50) {
      debugPrint(
        '🔍 Preamble at idx $bestIdx (${(bestScore * 100).toInt()}%) '
        '→ bad length $candidateLength, skipping',
      );
      _triedPositions.add(bestIdx);
      return;
    }

    // Both stages passed — commit!
    _preambleIndex = bestIdx;
    _payloadLength = candidateLength;
    _state = _RxState.receiving;
    debugPrint(
      '🚨 PREAMBLE LOCKED at idx $bestIdx '
      '(score: ${(bestScore * 100).toInt()}%)',
    );
    debugPrint('📦 Length header decoded: $_payloadLength data bytes');
    onPreambleFound?.call(bestIdx);

    // Immediately try to collect payload.
    _collectPayload(chips);
  }

  // ── Step 4: Payload collection + decode ─────────────────────────────

  void _collectPayload(String chips) {
    // Total packet bytes after the preamble:
    //   1 (length header) + _payloadLength (data) + _payloadLength (RS parity)
    // = 1 + 2 * _payloadLength
    // Each byte = 4 PPM symbols = 16 chips.
    final totalPayloadChips = (1 + 2 * _payloadLength) * 16;
    final payloadStart = _preambleIndex + preambleChips.length;

    if (chips.length < payloadStart + totalPayloadChips) return; // need more

    // Extract the data+parity chips (skip the 16-chip length header).
    final dataParityStart = payloadStart + 16;
    final dataParityChips = chips.substring(
      dataParityStart,
      dataParityStart + 2 * _payloadLength * 16,
    );

    debugPrint(
      '📡 Payload fully received: ${dataParityChips.length} chips '
      '(${2 * _payloadLength} bytes expected)',
    );

    // Demodulate 4-PPM → bytes (with erasure support).
    final demodBytes = _demodulateChips(dataParityChips);
    if (demodBytes == null) {
      onError?.call('4-PPM demodulation failed');
      reset();
      return;
    }

    debugPrint('🔢 Demodulated bytes: $demodBytes');

    // RS decode.
    _decodeWithRS(demodBytes);
  }

  // ── 4-PPM Demodulation ──────────────────────────────────────────────

  /// Demodulates a chip string into bytes.
  ///
  /// Each 4-chip group maps the position of the '1' to a 2-bit di-pair:
  ///   1000 → 00,  0100 → 01,  0010 → 10,  0001 → 11
  ///
  /// If a 4-chip group is `0000` (total dropout — e.g. bubble blocked the
  /// flash), the corresponding _byte_ is marked as `-1` (erasure) so that
  /// the Reed-Solomon decoder can use its more efficient erasure-correction
  /// path (1 symbol per erasure vs 2 per error), as described in the
  /// U-Flash paper's adaptive threshold demodulation scheme.
  static List<int>? _demodulateChips(String chips) {
    if (chips.length % 4 != 0) return null;

    final StringBuffer bitBuffer = StringBuffer();
    bool hasErasureInCurrentByte = false;
    final List<int> bytes = [];
    int diBitCount = 0;

    for (int i = 0; i < chips.length; i += 4) {
      final symbol = chips.substring(i, i + 4);

      // Find the position of the '1'.
      final pos = symbol.indexOf('1');

      if (pos == -1) {
        // No '1' found → erasure in this symbol.
        hasErasureInCurrentByte = true;
        bitBuffer.write('00'); // placeholder bits
      } else {
        bitBuffer.write(_ppmDecode[pos]);
      }

      diBitCount++;

      // Every 4 di-bits (4 PPM symbols) = 8 bits = 1 byte.
      if (diBitCount == 4) {
        if (hasErasureInCurrentByte) {
          bytes.add(-1); // RS erasure marker
        } else {
          bytes.add(int.parse(bitBuffer.toString(), radix: 2));
        }
        bitBuffer.clear();
        diBitCount = 0;
        hasErasureInCurrentByte = false;
      }
    }

    return bytes;
  }

  // ── Reed-Solomon Decode ─────────────────────────────────────────────

  void _decodeWithRS(List<int> demodBytes) {
    if (!_rsTablesReady) {
      initTables();
      _rsTablesReady = true;
    }

    final corrected = rsDecodePayload(demodBytes, _payloadLength);

    if (corrected == null) {
      debugPrint('❌ RS decode FAILED — damage exceeds correction capacity');
      onError?.call(
        'Reed-Solomon decode failed: too many errors/erasures to correct',
      );
      reset();
      return;
    }

    // Convert to UTF-8 text.
    try {
      final text = utf8.decode(corrected);
      debugPrint('✅ DECODED MESSAGE: "$text"');
      onPacketDecoded?.call(text);
    } catch (e) {
      debugPrint('❌ UTF-8 decode failed: $e');
      onError?.call('UTF-8 decode failed: $e');
    }

    reset();
  }
}
