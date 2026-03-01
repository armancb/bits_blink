import 'dart:convert';
import '../reed_solomon/galois_field.dart';
import '../reed_solomon/reed_solomon.dart';

import 'package:flutter/foundation.dart';

/// BITSBlink Decoder — Edge-Triggered Phase-Locked Loop.
///
/// Instead of histogram + run-length analysis, this decoder:
///   A. Finds every edge (transition) in the frame-level bitstream.
///   B. Uses preamble edges to calculate the dynamic chip width.
///   C. Detects the 11001100 sync word via its double-width edges.
///   D. Center-tap samples from the sync anchor at exact chip intervals.
class DecoderService {
  static bool _tablesInit = false;
  static void _ensureInit() {
    if (!_tablesInit) {
      initTables();
      _tablesInit = true;
    }
  }
  // ═══════════════════════════════════════════════════════════════
  //  MAIN DECODE PIPELINE
  // ═══════════════════════════════════════════════════════════════

  static DecodeResult decode(List<bool> frameBits) {
    if (frameBits.length < 20) {
      return DecodeResult(
        chipWidth: 0,
        error: 'Accumulating… (${frameBits.length} frames)',
        isNoSignal: true,
      );
    }

    // ── Step A: FIND ALL EDGES ──
    // An edge is a frame index where the value changes from the previous frame.
    final edges = <int>[];
    for (int i = 1; i < frameBits.length; i++) {
      if (frameBits[i] != frameBits[i - 1]) {
        edges.add(i);
      }
    }

    if (edges.length < 6) {
      return DecodeResult(
        chipWidth: 0,
        edgeCount: edges.length,
        error: 'Too few edges (${edges.length}/6+). Waiting for preamble…',
        isNoSignal: true,
      );
    }

    // ── Step B: CALCULATE DYNAMIC CLOCK FROM PREAMBLE ──
    // The preamble is 20 alternating chips: 10101010101010101010
    // Between each chip there is exactly one edge, spaced chipWidth frames apart.
    // Find the longest run of consistently-spaced edges → that's the preamble.
    final edgeSpacings = <double>[];
    for (int i = 1; i < edges.length; i++) {
      edgeSpacings.add((edges[i] - edges[i - 1]).toDouble());
    }

    // Find the preamble region: look for a run of ≥8 spacings that are
    // similar to each other (within ±40% of the median of that run).
    int bestRunStart = 0;
    int bestRunLen = 0;

    for (int start = 0; start < edgeSpacings.length; start++) {
      // Try a run starting here
      double sum = edgeSpacings[start];
      int count = 1;
      for (int j = start + 1; j < edgeSpacings.length; j++) {
        final avg = sum / count;
        // Check if this spacing is close to the running average
        if ((edgeSpacings[j] - avg).abs() / avg < 0.4) {
          sum += edgeSpacings[j];
          count++;
        } else {
          break;
        }
      }
      if (count > bestRunLen) {
        bestRunLen = count;
        bestRunStart = start;
      }
    }

    if (bestRunLen < 6) {
      return DecodeResult(
        chipWidth: 0,
        edgeCount: edges.length,
        error: 'No preamble found (best run: $bestRunLen edges, need ≥6)',
        isNoSignal: true,
      );
    }

    // Dynamic chip width = average spacing over the preamble edges
    double chipWidthF = 0;
    for (int i = bestRunStart; i < bestRunStart + bestRunLen; i++) {
      chipWidthF += edgeSpacings[i];
    }
    chipWidthF /= bestRunLen;

    // The preamble edges in the edge array
    final preambleEdgeStart = bestRunStart; // index into edges[]
    final preambleEdgeEnd =
        bestRunStart + bestRunLen; // index into edges[] (exclusive)

    debugPrint(
      '  PLL: chipWidth=${chipWidthF.toStringAsFixed(2)}f '
      '(from ${bestRunLen} preamble edges, edge[$preambleEdgeStart..$preambleEdgeEnd])',
    );

    // ── Step C: FIND SYNC WORD (11001100) ──
    // The sync word has a distinctive edge pattern:
    //   11 → edge after 2 chips
    //   00 → edge after 2 chips
    //   11 → edge after 2 chips
    //   00 → (no trailing edge unless data starts with 1)
    //
    // So the sync edges should be spaced at ~2× chipWidth apart.
    // We look for 2-3 consecutive spacings that are ~2× chipWidth right
    // after the preamble region.

    int syncAnchorEdge = -1; // The edge index where sync word ends
    int syncAnchorFrame = -1; // The frame index of that edge

    // Search from after the preamble for double-width spacings
    for (int i = preambleEdgeEnd; i < edges.length - 2; i++) {
      final s1 = edges[i + 1] - edges[i];
      final s2 = edges[i + 2] - edges[i + 1];

      // Both spacings should be close to 2× chipWidth
      final expected2x = chipWidthF * 2;
      if ((s1 - expected2x).abs() / expected2x < 0.4 &&
          (s2 - expected2x).abs() / expected2x < 0.4) {
        // Found the sync word! The anchor is after the sync word.
        // Edge i = start of sync (transition into first '1' of sync)
        // The sync word is 8 chips long from edge i.
        // Anchor = edge i's frame + 8 × chipWidth
        syncAnchorFrame = (edges[i] + (8 * chipWidthF)).round();
        syncAnchorEdge = i + 2;
        debugPrint(
          '  PLL: Sync found at edge[$i], '
          'frame=${edges[i]}, anchor=$syncAnchorFrame',
        );
        break;
      }
    }

    // Fallback: if no clear double-width pattern, try to find sync by
    // searching the first single-chip spacing AFTER a double-width gap
    if (syncAnchorEdge < 0) {
      for (int i = preambleEdgeEnd; i < edges.length - 1; i++) {
        final spacing = edges[i + 1] - edges[i];
        if (spacing > chipWidthF * 1.5) {
          // Found a gap > 1.5× chip → could be the start of sync
          syncAnchorFrame = (edges[i] + (8 * chipWidthF)).round();
          syncAnchorEdge = i;
          debugPrint(
            '  PLL: Sync (fallback) at edge[$i], '
            'frame=${edges[i]}, anchor=$syncAnchorFrame',
          );
          break;
        }
      }
    }

    if (syncAnchorEdge < 0 || syncAnchorFrame < 0) {
      return DecodeResult(
        chipWidth: chipWidthF.round(),
        chipWidthExact: chipWidthF,
        edgeCount: edges.length,
        preambleFound: true,
        error:
            'Sync word not found (${edges.length - preambleEdgeEnd} edges after preamble)',
      );
    }

    // ── Step D: CENTER-TAP SAMPLING ──
    // Drop sampling anchor at syncAnchorFrame.
    // Step forward by chipWidth/2 to land in the CENTER of the first data chip.
    // Then step by chipWidth for each subsequent chip.

    if (syncAnchorFrame >= frameBits.length) {
      return DecodeResult(
        chipWidth: chipWidthF.round(),
        chipWidthExact: chipWidthF,
        edgeCount: edges.length,
        preambleFound: true,
        syncFound: true,
        error: 'Sync found, waiting for data frames…',
      );
    }

    // First chip center
    double samplePos = syncAnchorFrame + chipWidthF / 2;

    // We need 8 bits for length + N×8 bits for data.
    // First, read the length byte.
    final sampledBits = <bool>[];
    final maxBits = 256 * 8 + 8; // max 255 data bytes + length byte

    while (samplePos < frameBits.length && sampledBits.length < maxBits) {
      final idx = samplePos.round().clamp(0, frameBits.length - 1);
      sampledBits.add(frameBits[idx]);
      samplePos += chipWidthF;
    }

    if (sampledBits.length < 8) {
      return DecodeResult(
        chipWidth: chipWidthF.round(),
        chipWidthExact: chipWidthF,
        edgeCount: edges.length,
        preambleFound: true,
        syncFound: true,
        resampledBits: _boolsToStr(sampledBits),
        error: 'Need ≥8 data chips (have ${sampledBits.length})',
      );
    }

    // ── Step E: LENGTH + DATA EXTRACTION (with RS) ──
    _ensureInit();
    final lengthByte = _bitsToByteAt(sampledBits, 0);

    if (lengthByte <= 0 || lengthByte > 127) {
      return DecodeResult(
        chipWidth: chipWidthF.round(),
        chipWidthExact: chipWidthF,
        edgeCount: edges.length,
        preambleFound: true,
        syncFound: true,
        resampledBits: _boolsToStr(sampledBits),
        error:
            'Invalid length: $lengthByte (raw bits: ${_boolsToStr(sampledBits.take(8).toList())})',
      );
    }

    // RS uses 1:1 parity ratio, so total encoded = lengthByte * 2
    final int totalRsBytes = lengthByte * 2;
    final int totalBitsNeeded = 8 + totalRsBytes * 8;

    if (sampledBits.length < totalBitsNeeded) {
      final haveBytes = (sampledBits.length - 8) ~/ 8;
      return DecodeResult(
        chipWidth: chipWidthF.round(),
        chipWidthExact: chipWidthF,
        edgeCount: edges.length,
        dataLength: lengthByte,
        preambleFound: true,
        syncFound: true,
        resampledBits: _boolsToStr(sampledBits),
        error: 'Receiving… ($haveBytes/$totalRsBytes bytes)',
      );
    }

    // Extract all RS-encoded bytes (data + parity)
    final rsBytes = <int>[];
    for (int i = 0; i < totalRsBytes; i++) {
      rsBytes.add(_bitsToByteAt(sampledBits, 8 + i * 8));
    }

    // Try RS error correction
    List<int>? correctedData;
    bool rsSuccess = false;
    try {
      correctedData = rsDecodePayload(rsBytes, lengthByte);
      rsSuccess = correctedData != null;
    } catch (e) {
      debugPrint('  PLL: RS correction failed: $e');
    }

    // Fallback: use raw data bytes if RS fails
    final dataBytes = correctedData ?? rsBytes.sublist(0, lengthByte);

    // UTF-8 decode
    String decodedText;
    try {
      decodedText = utf8.decode(dataBytes, allowMalformed: true);
    } catch (e) {
      decodedText = dataBytes.map((b) => String.fromCharCode(b)).join();
    }

    debugPrint(
      '  PLL: DECODED "$decodedText" '
      '(${dataBytes.length} bytes, RS=${rsSuccess ? "OK" : "FAIL"}, '
      'chipW=${chipWidthF.toStringAsFixed(2)})',
    );

    return DecodeResult(
      chipWidth: chipWidthF.round(),
      chipWidthExact: chipWidthF,
      edgeCount: edges.length,
      dataLength: lengthByte,
      dataBytes: dataBytes,
      decodedText: decodedText,
      preambleFound: true,
      syncFound: true,
      rsSuccess: rsSuccess,
      resampledBits: _boolsToStr(sampledBits),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  HELPERS
  // ═══════════════════════════════════════════════════════════════

  /// Read 8 bits from [bits] starting at [offset] → byte value.
  static int _bitsToByteAt(List<bool> bits, int offset) {
    int value = 0;
    for (int i = 0; i < 8; i++) {
      if (offset + i < bits.length && bits[offset + i]) {
        value |= (1 << (7 - i));
      }
    }
    return value;
  }

  static String _boolsToStr(List<bool> bits) {
    return bits.map((b) => b ? '1' : '0').join();
  }
}

// ═══════════════════════════════════════════════════════════════
//  DECODE RESULT
// ═══════════════════════════════════════════════════════════════

class DecodeResult {
  final int chipWidth;
  final double? chipWidthExact;
  final int? edgeCount;
  final String? resampledBits;
  final int? dataLength;
  final List<int>? dataBytes;
  final String? decodedText;
  final String? error;
  final bool isNoSignal;
  final bool preambleFound;
  final bool syncFound;
  final bool rsSuccess;

  bool get success => decodedText != null && error == null;

  const DecodeResult({
    required this.chipWidth,
    this.chipWidthExact,
    this.edgeCount,
    this.resampledBits,
    this.dataLength,
    this.dataBytes,
    this.decodedText,
    this.error,
    this.isNoSignal = false,
    this.preambleFound = false,
    this.syncFound = false,
    this.rsSuccess = false,
  });
}
