import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../reed_solomon/galois_field.dart';
import '../reed_solomon/reed_solomon.dart';

/// BITSBlink Encoder — Direct OOK with RS error correction.
///
/// Packet format:
///   1. PREAMBLE:  20 alternating chips (10101010101010101010)
///   2. SYNC WORD: 11001100 (8 chips)
///   3. LENGTH:    8 chips (ORIGINAL data byte count, max 127)
///   4. DATA+PAR:  (length × 2) × 8 chips (RS-encoded: data + parity)
///
/// RS uses GF(256) with prim=0x11D, nsym = dataLength (1:1 parity).
class EncoderService {
  static bool _tablesInit = false;
  static void _ensureInit() {
    if (!_tablesInit) {
      initTables();
      _tablesInit = true;
    }
  }

  /// 20-chip alternating preamble for clock calibration.
  static const List<bool> preamble = [
    true,
    false,
    true,
    false,
    true,
    false,
    true,
    false,
    true,
    false,
    true,
    false,
    true,
    false,
    true,
    false,
    true,
    false,
    true,
    false,
  ];

  /// Sync word: 11001100 — violates the alternating pattern.
  static const List<bool> syncWord = [
    true,
    true,
    false,
    false,
    true,
    true,
    false,
    false,
  ];

  /// Encode a text message into a chip signal (List<bool>).
  static List<bool> encode(String text) {
    _ensureInit();

    final utf8Bytes = utf8.encode(text);
    final length = utf8Bytes.length;

    if (length > 127) {
      throw ArgumentError('Message too long: $length bytes (max 127)');
    }

    // RS encode with 1:1 parity
    final rsEncoded = rsEncodeMessage(utf8Bytes, length);
    // rsEncoded = [data (length bytes) | parity (length bytes)]

    final chips = <bool>[];

    // 1. Preamble (20 chips)
    chips.addAll(preamble);

    // 2. Sync word (8 chips)
    chips.addAll(syncWord);

    // 3. Length byte — ORIGINAL data length (8 chips)
    chips.addAll(_byteToBits(length));

    // 4. RS-encoded bytes: data + parity (length*2 × 8 chips)
    for (final byte in rsEncoded) {
      chips.addAll(_byteToBits(byte));
    }

    debugPrint('═══════════════════════════════════════════');
    debugPrint('  BITSBlink Encoder (OOK + RS)');
    debugPrint('  Text     : "$text"');
    debugPrint('  Bytes    : $utf8Bytes');
    debugPrint(
      '  RS data  : ${rsEncoded.length} bytes (${length}d + ${length}p)',
    );
    debugPrint('  Chips    : ${chips.length} total');
    debugPrint('═══════════════════════════════════════════');

    return chips;
  }

  /// Convert a byte (0–255) into 8 bits (MSB first).
  static List<bool> _byteToBits(int byte) {
    return List.generate(8, (i) => (byte >> (7 - i)) & 1 == 1);
  }
}
