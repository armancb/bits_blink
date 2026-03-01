import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../reed_solomon/galois_field.dart';
import '../reed_solomon/reed_solomon.dart';

/// Receiver state machine phases.
enum _RxState { hunting, receiving }

/// DSP (Digital Signal Processing) Service for the 4-PPM optical modem
/// receiver pipeline.
///
/// This is a **stateful** service: call [feedFrame] with every raw bitstring
/// from the native EventChannel. It will hunt for the preamble using
/// frame-level correlation (robust to jitter), then extract payload chips
/// at the recovered clock rate, RS-decode, and fire callbacks.
class DSPService {
  // ── Protocol constants ──────────────────────────────────────────────

  /// Camera rows per flash slot (oversampling factor).
  /// Auto-calibrated from first frame if set to 0.
  int samplesPerSlot;

  /// 4-PPM chip representation of the SFD (0xAA 0xAA = two bytes).
  static const String sfdChips = '00100010001000100010001000100010';

  /// 4-PPM chip representation of the EFD (0x55 0x55 = two bytes).
  static const String efdChips = '00010100010001000001010001000100';

  /// Reverse look-up: position of the '1' in a 4-chip symbol → di-bit.
  static const List<String> _ppmDecode = ['00', '01', '10', '11'];

  // ── Callbacks ───────────────────────────────────────────────────────

  final void Function(int chipIndex)? onPreambleFound;
  final void Function(String decodedText)? onPacketDecoded;
  final void Function(String message)? onError;
  final void Function(String chips)? onChipsUpdated;

  // ── Internal state ──────────────────────────────────────────────────

  final StringBuffer _chipAccumulator = StringBuffer();

  _RxState _state = _RxState.hunting;
  int _preambleIndex = -1;
  int _payloadLength = -1;
  bool _rsTablesReady = false;

  // ── Carry-over state (incremental RLE across frame boundaries) ─────
  String _lastChar = '';
  int _pendingRunLength = 0;

  // ── Burst tracking ─────────────────────────────────────────────────
  bool _inBurst = false;
  int _silentFrameCount = 0;
  // 4-PPM worst case: 6 consecutive OFF chips across byte boundaries
  // = 12 frames at 2 frames/chip. Add margin for jitter → 25.
  static const int _maxSilentFrames = 25;

  // ── Receiving timeout ──────────────────────────────────────────────
  int _receivingFrameCount = 0;
  int _maxReceivingFrames = 600;

  // ── Frame-level vote buffer ────────────────────────────────────────
  // One entry per frame (0 = OFF, 1 = ON). Used for robust preamble
  // hunting via frame-rate correlation, bypassing RLE chip conversion.
  final List<int> _frameVotes = [];
  int _preambleFrameStart = -1;
  double _calibratedFpc = 2.0; // frames-per-chip, recovered from preamble
  bool _frameLevelLock = false;
  bool _homogeneousFrames = true; // tracks if all frames are homogeneous
  static const int _maxPreBurstVotes = 100; // keep recent silence for preamble leading zeros

  DSPService({
    this.samplesPerSlot = 0, // 0 = auto-calibrate from first frame
    this.onPreambleFound,
    this.onPacketDecoded,
    this.onError,
    this.onChipsUpdated,
  });

  // ── Public API ──────────────────────────────────────────────────────

  int _feedFrameCount = 0;

  void feedFrame(String rawBits) {
    if (rawBits.isEmpty) return;

    // Auto-calibrate samplesPerSlot from actual camera row count.
    // When frames are homogeneous (all-1 or all-0), each frame is one
    // "slot" in RLE terms. Set samplesPerSlot = rows in one frame so
    // that one homogeneous frame → 1 chip in the RLE path.
    if (samplesPerSlot == 0) {
      samplesPerSlot = rawBits.length;
      debugPrint(
        '📐 Auto-calibrated samplesPerSlot = $samplesPerSlot '
        '(${rawBits.length} rows per frame)',
      );
    }

    _feedFrameCount++;
    final bool hasSignal = rawBits.contains('1');
    final bool isHeartbeat = _feedFrameCount % 30 == 1;

    // ── Debug logging ──
    if (hasSignal || isHeartbeat) {
      final runs = <String>[];
      int runStart = 0;
      for (int i = 1; i <= rawBits.length; i++) {
        if (i == rawBits.length || rawBits[i] != rawBits[runStart]) {
          runs.add('${rawBits[runStart]}×${i - runStart}');
          runStart = i;
        }
      }
      final preview = runs.take(10).join(', ');
      final tag = hasSignal ? '🔴 SIGNAL' : '📊';
      debugPrint(
        '$tag F#$_feedFrameCount raw RLE: $preview'
        '${runs.length > 10 ? " ... (${runs.length} total runs)" : ""}',
      );
    }

    // ── Burst tracking ──
    if (hasSignal) {
      _silentFrameCount = 0;
      _inBurst = true;
    } else {
      _silentFrameCount++;
    }

    // ── ALWAYS record frame vote (including pre-burst silence) ──
    // The preamble starts with leading zeros that occur BEFORE the first
    // ON frame. Without these zeros, the frame-level correlator can never
    // align the template correctly.
    _frameVotes.add(hasSignal ? 1 : 0);

    // Trim pre-burst buffer to avoid unbounded growth during long silence.
    if (!_inBurst && _frameVotes.length > _maxPreBurstVotes) {
      _frameVotes.removeRange(0, _frameVotes.length - _maxPreBurstVotes);
    }

    // If we haven't seen any signal yet, skip RLE processing.
    if (!_inBurst) {
      if (isHeartbeat) {
        debugPrint(
          '📊 F#$_feedFrameCount → skipped (no burst), '
          'chips=${_chipAccumulator.length}, state=$_state',
        );
      }
      return;
    }

    // If silence exceeded threshold, end the burst.
    if (_silentFrameCount > _maxSilentFrames) {
      if (_pendingRunLength > 0) {
        _emitRun(_chipAccumulator, _lastChar, _pendingRunLength);
        _pendingRunLength = 0;
        _lastChar = '';
      }
      _inBurst = false;

      if (_state == _RxState.receiving) {
        debugPrint(
          '⏰ Burst ended while receiving — payload incomplete, resetting',
        );
        onError?.call('Reception timeout: burst ended before payload complete');
        reset();
      }

      if (isHeartbeat) {
        debugPrint(
          '📊 F#$_feedFrameCount → burst ended after $_maxSilentFrames '
          'silent frames, chips=${_chipAccumulator.length}',
        );
      }
      return;
    }

    // ── Process this frame incrementally (carry-over RLE) ──
    _downsampleFrame(rawBits);

    final chips = _snapshotChips();

    if (hasSignal || isHeartbeat) {
      debugPrint(
        '📊 F#$_feedFrameCount → ${chips.length} chips, '
        'pending=${_pendingRunLength}$_lastChar, state=$_state',
      );
    }

    onChipsUpdated?.call(chips);

    // ── Safety cap (hunting mode only) ──
    if (_state == _RxState.hunting && chips.length > 5000) {
      final trimmed = chips.substring(chips.length - 2000);
      _chipAccumulator.clear();
      _chipAccumulator.write(trimmed);
      _triedPositions.clear();
    }

    // ── State machine ──
    switch (_state) {
      case _RxState.hunting:
        // Frame-level hunting (robust to jitter, preferred for camera data)
        _huntPreambleFrameLevel();
        // Only fall back to chip-level for NON-homogeneous data (tests)
        if (_state == _RxState.hunting && !_homogeneousFrames) {
          _huntPreamble(chips);
        }
      case _RxState.receiving:
        _receivingFrameCount++;
        if (_receivingFrameCount > _maxReceivingFrames) {
          debugPrint(
            '⏰ Receiving timeout after $_receivingFrameCount frames '
            '(max=$_maxReceivingFrames) — resetting',
          );
          onError?.call('Reception timeout: too many frames without payload');
          reset();
          return;
        }
        if (_frameLevelLock) {
          _collectPayloadFrameLevel();
        } else {
          _collectPayload(chips);
        }
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
    _inBurst = false;
    _silentFrameCount = 0;
    _receivingFrameCount = 0;
    _maxReceivingFrames = 600;
    _triedPositions.clear();
    _feedFrameCount = 0;
    _frameVotes.clear();
    _preambleFrameStart = -1;
    _calibratedFpc = 2.0;
    _frameLevelLock = false;
    _decodeAttempts = 0;
    _homogeneousFrames = true;
  }

  // ── Step 1: Incremental downsampling (carry-over RLE) ───────────────

  void _downsampleFrame(String rawBits) {
    final firstChar = rawBits[0];
    bool homogeneous = true;
    final step = rawBits.length > 100 ? rawBits.length ~/ 10 : 1;
    for (int i = step; i < rawBits.length; i += step) {
      if (rawBits[i] != firstChar) {
        homogeneous = false;
        break;
      }
    }

    if (homogeneous) {
      if (_lastChar.isEmpty || _lastChar == firstChar) {
        _lastChar = firstChar;
        _pendingRunLength += rawBits.length;
      } else {
        _emitRun(_chipAccumulator, _lastChar, _pendingRunLength);
        _lastChar = firstChar;
        _pendingRunLength = rawBits.length;
      }
      return;
    }

    _homogeneousFrames = false; // enable chip-level fallback for test data
    for (int i = 0; i < rawBits.length; i++) {
      final c = rawBits[i];
      if (_lastChar.isEmpty) {
        _lastChar = c;
        _pendingRunLength = 1;
      } else if (c == _lastChar) {
        _pendingRunLength++;
      } else {
        _emitRun(_chipAccumulator, _lastChar, _pendingRunLength);
        _lastChar = c;
        _pendingRunLength = 1;
      }
    }
  }

  String _snapshotChips() {
    if (_pendingRunLength > 0 && _lastChar.isNotEmpty) {
      final preview = StringBuffer();
      _emitRun(preview, _lastChar, _pendingRunLength);
      return '${_chipAccumulator.toString()}${preview.toString()}';
    }
    return _chipAccumulator.toString();
  }

  void _emitRun(StringBuffer buffer, String char, int runLength) {
    int slots = (runLength / samplesPerSlot).round();

    final minRunForChip = (samplesPerSlot * 0.6).round();
    if (runLength < minRunForChip) {
      slots = 0;
    } else if (runLength >= minRunForChip && slots == 0) {
      slots = 1;
    }

    for (int s = 0; s < slots; s++) {
      buffer.write(char);
    }
  }

  // ── Frame-level preamble hunting (robust to jitter) ─────────────────

  /// Extracts chip values from frame votes using majority voting over
  /// a window of [fpc] frames per chip.
  int _voteChip(int frameStart, double fpc) {
    int ones = 0;
    int total = 0;
    final fpcInt = fpc.round();
    for (int f = frameStart; f < frameStart + fpcInt && f < _frameVotes.length; f++) {
      ones += _frameVotes[f];
      total++;
    }
    if (total == 0) return 0;
    return ones > total / 2 ? 1 : 0;
  }

  String _extractChipsFromFrameVotes(int startFrame, int numChips, double fpc) {
    final buf = StringBuffer();
    for (int c = 0; c < numChips; c++) {
      final frameIdx = startFrame + (c * fpc).round();
      buf.write(_voteChip(frameIdx, fpc));
    }
    return buf.toString();
  }

  void _huntPreambleFrameLevel() {
    if (_frameVotes.length < 60) return; // need enough frames

    double bestScore = 0;
    int bestStart = -1;
    double bestFpc = 2.0;
    int bestOnesMatched = 0;

    // Try different frames-per-chip rates to handle TX/RX clock drift.
    // Constrained to ±15% of the expected 2.0 fpc to avoid false matches.
    for (double fpc = 1.8; fpc <= 2.3; fpc += 0.05) {
      final templateFrames = (sfdChips.length * fpc).round();
      // Need template + at least 32 frames for header validation
      if (_frameVotes.length < templateFrames + 40) continue;

      for (int start = 0; start <= _frameVotes.length - templateFrames - 40; start++) {
        int matches = 0;
        int onesMatched = 0;

        for (int j = 0; j < sfdChips.length; j++) {
          final expected = int.parse(sfdChips[j]);
          final frameIdx = start + (j * fpc).round();
          final actual = _voteChip(frameIdx, fpc);

          if (actual == expected) {
            matches++;
            if (expected == 1) onesMatched++;
          }
        }

        final score = matches / sfdChips.length;
        // Require at least 6 of 8 SFD ON-chips to match
        if (score > bestScore && onesMatched >= 6) {
          bestScore = score;
          bestStart = start;
          bestFpc = fpc;
          bestOnesMatched = onesMatched;
        }
      }
    }

    if (bestScore < _preambleThreshold) {
      if (_feedFrameCount % 10 == 0 && bestScore > 0.0) {
        debugPrint(
          '🔍 Frame-level best: ${(bestScore * 100).toInt()}% '
          'at frame $bestStart (fpc=${bestFpc.toStringAsFixed(2)}, '
          'ones=$bestOnesMatched/8, votes=${_frameVotes.length})',
        );
      }
      return;
    }

    // ── Validate: extract length header from frame votes ──
    final headerStartFrame =
        bestStart + (sfdChips.length * bestFpc).round();

    for (final offsetFrames in [0, -1, 1, -2, 2]) {
      final hStart = headerStartFrame + offsetFrames;
      if (hStart < 0) continue;

      final headerChips = _extractChipsFromFrameVotes(hStart, 16, bestFpc);
      final headerBytes = _demodulateChips(headerChips);
      if (headerBytes == null || headerBytes.isEmpty) continue;

      final candidateLength = headerBytes[0];
      if (candidateLength <= 0 || candidateLength > 20) continue;

      // ── Commit frame-level lock ──
      _preambleFrameStart = bestStart;
      _calibratedFpc = bestFpc;
      _payloadLength = candidateLength;
      _state = _RxState.receiving;
      _receivingFrameCount = 0;
      _frameLevelLock = true;

      const int rsParityCount = 8;
      // Total payload chips: length(16) + (data+parity)*16 + EFD(32)
      final totalPayloadChips = (1 + _payloadLength + rsParityCount) * 16 + efdChips.length;
      _maxReceivingFrames = (totalPayloadChips * bestFpc * 1.5).round() + 200;

      debugPrint(
        '🚨 FRAME-LEVEL PREAMBLE LOCKED at frame $bestStart '
        '(score: ${(bestScore * 100).toInt()}%, '
        'fpc: ${bestFpc.toStringAsFixed(1)}, offset: $offsetFrames)',
      );
      debugPrint(
        '📦 Length header decoded: $_payloadLength data bytes '
        '(rx timeout: $_maxReceivingFrames frames)',
      );
      onPreambleFound?.call(bestStart);
      _collectPayloadFrameLevel();
      return;
    }

    debugPrint(
      '🔍 Frame-level preamble at frame $bestStart '
      '(${(bestScore * 100).toInt()}%) → header validation failed',
    );
  }

  // ── Frame-level payload collection ──────────────────────────────────

  void _collectPayloadFrameLevel() {
    const int rsParityCount = 8;
    // Total chips after SFD: length(16) + (data+parity)*16 + EFD(32)
    final totalChipsAfterSfd = (1 + _payloadLength + rsParityCount) * 16 + efdChips.length;
    final payloadStartFrame =
        _preambleFrameStart + (sfdChips.length * _calibratedFpc).round();
    final totalFramesNeeded =
        payloadStartFrame + (totalChipsAfterSfd * _calibratedFpc).round();

    if (_frameVotes.length < totalFramesNeeded) return;

    // Extract all payload chips (header + data + parity + EFD)
    final allChips = _extractChipsFromFrameVotes(
      payloadStartFrame,
      totalChipsAfterSfd,
      _calibratedFpc,
    );

    // Skip the 16-chip length header
    final dataParityChipsLength = (_payloadLength + rsParityCount) * 16;
    final dataParityChips = allChips.substring(16, 16 + dataParityChipsLength);
    final efdChipsRx = allChips.substring(16 + dataParityChipsLength);

    debugPrint(
      '📡 Frame-level payload received: ${dataParityChips.length} chips '
      '(${_payloadLength + rsParityCount} bytes expected)',
    );

    // Validate EFD (0x55 0x55)
    final efdDecoded = _demodulateChips(efdChipsRx);
    if (efdDecoded != null && efdDecoded.length >= 2 &&
        efdDecoded[0] == 0x55 && efdDecoded[1] == 0x55) {
      debugPrint('🏁 EFD validated! (0x55 0x55)');
    } else {
      debugPrint('⚠️ EFD mismatch or erasure, trying to decode payload anyway...');
    }

    final demodBytes = _demodulateChips(dataParityChips);
    if (demodBytes == null) {
      onError?.call('4-PPM demodulation failed');
      reset();
      return;
    }

    debugPrint('🔢 Demodulated bytes: $demodBytes');
    _decodeWithRS(demodBytes);
  }

  // ── Chip-level preamble hunting (fallback for non-homogeneous) ──────

  static const double _preambleThreshold = 0.80;
  final Set<int> _triedPositions = {};

  void _huntPreamble(String chips) {
    if (chips.length < sfdChips.length + 16) return;

    int bestIdx = -1;
    double bestScore = 0.0;
    int bestWindowLen = sfdChips.length;

    for (int i = 0; i <= chips.length - sfdChips.length - 16; i++) {
      if (_triedPositions.contains(i)) continue;

      int matches = 0;
      int onesMatched = 0;
      for (int j = 0; j < sfdChips.length; j++) {
        if (chips[i + j] == sfdChips[j]) {
          matches++;
          if (sfdChips[j] == '1') onesMatched++;
        }
      }
      final score = matches / sfdChips.length;
      if (score > bestScore && onesMatched >= 7) {
        bestScore = score;
        bestIdx = i;
        bestWindowLen = sfdChips.length;
      }
    }

    // Also try stretched/compressed preamble windows (±2 chips).
    for (int stretch = -2; stretch <= 2; stretch++) {
      if (stretch == 0) continue;
      final windowLen = sfdChips.length + stretch;
      if (windowLen < 16 || chips.length < windowLen + 16) continue;

      for (int i = 0; i <= chips.length - windowLen - 16; i++) {
        if (_triedPositions.contains(i)) continue;

        int matches = 0;
        int onesMatched = 0;
        for (int j = 0; j < sfdChips.length; j++) {
          final mappedIdx =
              i + (j * windowLen / sfdChips.length).round();
          if (mappedIdx < chips.length &&
              chips[mappedIdx] == sfdChips[j]) {
            matches++;
            if (sfdChips[j] == '1') onesMatched++;
          }
        }
        final score = matches / sfdChips.length;
        if (score > bestScore && onesMatched >= 7) {
          bestScore = score;
          bestIdx = i;
          bestWindowLen = windowLen;
        }
      }
    }

    if (bestScore < _preambleThreshold) {
      if (_feedFrameCount % 30 == 0 && bestScore > 0.3) {
        debugPrint(
          '🔍 Best preamble score: ${(bestScore * 100).toInt()}% '
          'at idx $bestIdx (need ${(_preambleThreshold * 100).toInt()}%)',
        );
      }
      return;
    }

    final headerStart = bestIdx + bestWindowLen;

    for (final offset in [0, -1, 1, -2, 2]) {
      final hStart = headerStart + offset;
      if (hStart < 0 || chips.length < hStart + 16) continue;

      final headerChips = chips.substring(hStart, hStart + 16);
      final headerBytes = _demodulateChips(headerChips);
      if (headerBytes == null || headerBytes.isEmpty) continue;

      final candidateLength = headerBytes[0];
      if (candidateLength <= 0 || candidateLength > 20) continue;

      _preambleIndex = bestIdx;
      _payloadLength = candidateLength;
      _state = _RxState.receiving;
      _receivingFrameCount = 0;

      const int rsParityCount = 8;
      // Total payload chips: length(16) + (data+parity)*16 + EFD(32)
      final totalPayloadChips = (1 + _payloadLength + rsParityCount) * 16 + efdChips.length;
      _maxReceivingFrames = totalPayloadChips * 3 + 150;

      debugPrint(
        '🚨 PREAMBLE LOCKED at idx $bestIdx '
        '(score: ${(bestScore * 100).toInt()}%, '
        'header offset: $offset)',
      );
      debugPrint(
        '📦 Length header decoded: $_payloadLength data bytes '
        '(rx timeout: $_maxReceivingFrames frames)',
      );
      onPreambleFound?.call(bestIdx);

      _collectPayload(chips);
      return;
    }

    debugPrint(
      '🔍 Preamble at idx $bestIdx (${(bestScore * 100).toInt()}%) '
      '→ header demod failed at all offsets, skipping',
    );
    _triedPositions.add(bestIdx);
  }

  // ── Chip-level payload collection (fallback) ────────────────────────

  void _collectPayload(String chips) {
    const int rsParityCount = 8;
    // Total payload chips: length(16) + (data+parity)*16 + EFD(32)
    final totalPayloadChips = (1 + _payloadLength + rsParityCount) * 16 + efdChips.length;
    final payloadStart = _preambleIndex + sfdChips.length;

    if (chips.length < payloadStart + totalPayloadChips) return;

    final dataParityStart = payloadStart + 16;
    final dataParityChipsLength = (_payloadLength + rsParityCount) * 16;
    final dataParityChips = chips.substring(
      dataParityStart,
      dataParityStart + dataParityChipsLength,
    );
    final efdStart = dataParityStart + dataParityChipsLength;
    final efdChipsRx = chips.substring(efdStart, efdStart + efdChips.length);

    debugPrint(
      '📡 Payload fully received: ${dataParityChips.length} chips '
      '(${_payloadLength + rsParityCount} bytes expected)',
    );

    // Validate EFD (0x55 0x55)
    final efdDecoded = _demodulateChips(efdChipsRx);
    if (efdDecoded != null && efdDecoded.length >= 2 &&
        efdDecoded[0] == 0x55 && efdDecoded[1] == 0x55) {
      debugPrint('🏁 EFD validated! (0x55 0x55)');
    } else {
      debugPrint('⚠️ EFD mismatch or erasure, trying to decode payload anyway...');
    }

    final demodBytes = _demodulateChips(dataParityChips);
    if (demodBytes == null) {
      onError?.call('4-PPM demodulation failed');
      reset();
      return;
    }

    debugPrint('🔢 Demodulated bytes: $demodBytes');
    _decodeWithRS(demodBytes);
  }

  // ── 4-PPM Demodulation ──────────────────────────────────────────────

  static List<int>? _demodulateChips(String chips) {
    if (chips.length % 4 != 0) return null;

    final StringBuffer bitBuffer = StringBuffer();
    bool hasErasureInCurrentByte = false;
    final List<int> bytes = [];
    int diBitCount = 0;

    for (int i = 0; i < chips.length; i += 4) {
      final symbol = chips.substring(i, i + 4);
      final pos = symbol.indexOf('1');

      if (pos == -1) {
        hasErasureInCurrentByte = true;
        bitBuffer.write('00');
      } else {
        bitBuffer.write(_ppmDecode[pos]);
      }

      diBitCount++;

      if (diBitCount == 4) {
        if (hasErasureInCurrentByte) {
          bytes.add(-1);
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

  int _decodeAttempts = 0;
  static const int _maxDecodeAttempts = 3;

  /// On RS failure, go back to hunting mode (keeping frame buffer)
  /// so the next copy's preamble can be found.
  void _resumeHunting() {
    _state = _RxState.hunting;
    _preambleIndex = -1;
    _payloadLength = -1;
    _preambleFrameStart = -1;
    _frameLevelLock = false;
    _receivingFrameCount = 0;
    _triedPositions.clear();
    // Keep _frameVotes, _chipAccumulator, carry-over state, and burst state!
    debugPrint(
      '🔄 Resuming hunt for next copy (attempt ${_decodeAttempts + 1}/$_maxDecodeAttempts)',
    );
  }

  void _decodeWithRS(List<int> demodBytes) {
    if (!_rsTablesReady) {
      initTables();
      _rsTablesReady = true;
    }

    final corrected = rsDecodePayload(demodBytes, _payloadLength);

    if (corrected == null) {
      _decodeAttempts++;
      debugPrint(
        '❌ RS decode FAILED (attempt $_decodeAttempts/$_maxDecodeAttempts) '
        '— damage exceeds correction capacity',
      );

      if (_decodeAttempts >= _maxDecodeAttempts) {
        debugPrint('❌ All $_maxDecodeAttempts attempts exhausted — giving up');
        onError?.call(
          'Reed-Solomon decode failed after $_maxDecodeAttempts attempts',
        );
        reset();
      } else {
        // Go back to hunting — the next redundant copy may still be coming.
        _resumeHunting();
      }
      return;
    }

    try {
      final text = utf8.decode(corrected);
      debugPrint(
        '✅ DECODED MESSAGE: "$text" '
        '(on attempt ${_decodeAttempts + 1})',
      );
      onPacketDecoded?.call(text);
    } catch (e) {
      debugPrint('❌ UTF-8 decode failed: $e');
      onError?.call('UTF-8 decode failed: $e');
    }

    reset();
  }
}
