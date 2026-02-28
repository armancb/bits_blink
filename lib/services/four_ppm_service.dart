import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../reed_solomon/galois_field.dart';
import '../reed_solomon/reed_solomon.dart';

/// 4-PPM (4-Pulse Position Modulation) Service.
///
/// In 4-PPM every 2 data bits are mapped to a 4-chip symbol
/// where exactly one chip position is HIGH:
///   00 → 1 0 0 0
///   01 → 0 1 0 0
///   10 → 0 0 1 0
///   11 → 0 0 0 1
class FourPpmService {
  // ── 4-PPM look-up table ──────────────────────────────────────────
  static const Map<String, String> _ppmTable = {
    '00': '1000',
    '01': '0100',
    '10': '0010',
    '11': '0001',
  };

  /// Preamble byte (0xAA = 170) used to signal start of transmission.
  static const int _preambleByte = 170;

  static bool _tablesInitialised = false;

  /// Ensures GF(256) lookup tables are built once.
  static void _ensureInit() {
    if (!_tablesInitialised) {
      initTables();
      _tablesInitialised = true;
    }
  }

  /// Converts a single byte to an 8-bit binary string.
  static String _toBinary(int byte) => byte.toRadixString(2).padLeft(8, '0');

  /// Takes a list of packet bytes and returns the full 4-PPM chip
  /// sequence as a string of '1's and '0's.
  static String modulateTo4Ppm(List<int> packetBytes) {
    // Convert every byte → 8-bit binary → take 2 bits at a time → map
    final buffer = StringBuffer();

    for (final byte in packetBytes) {
      final bits = _toBinary(byte); // 8 bits → 4 di-bits → 4 PPM symbols
      for (int i = 0; i < bits.length; i += 2) {
        final diBit = bits.substring(i, i + 2);
        buffer.write(_ppmTable[diBit]);
        buffer.write(' '); // space between symbols for readability
      }
    }

    return buffer.toString().trimRight();
  }

  /// Full pipeline: takes the original text, encodes it (UTF-8 + RS),
  /// builds the final packet, applies 4-PPM modulation, and prints
  /// everything to the debug console.
  static void encodeAndModulate(String text) {
    _ensureInit();

    final words = text.split(RegExp(r'\s+'));

    debugPrint('');
    debugPrint('╔═══════════════════════════════════════════════════╗');
    debugPrint('║        BITSBlink  4-PPM Modulation Output        ║');
    debugPrint('╚═══════════════════════════════════════════════════╝');
    debugPrint('  Original : "$text"');
    debugPrint('  Words    : $words');
    debugPrint('───────────────────────────────────────────────────');

    for (final word in words) {
      // Step 1: UTF-8 encode
      final utf8Bytes = utf8.encode(word);
      final messageLength = utf8Bytes.length;

      // Step 2: RS encode with 1:1 parity (nsym = message length)
      final rsEncoded = rsEncodeMessage(utf8Bytes, messageLength);

      // Step 3: Build final packet — [preamble][length][data + parity]
      final packet = <int>[_preambleByte, messageLength, ...rsEncoded];

      // Step 4: Binary representation (for reference)
      final binaryStr = packet.map(_toBinary).join(' ');

      // Step 5: 4-PPM modulation
      final ppmOutput = modulateTo4Ppm(packet);

      debugPrint('  Word         : "$word"');
      debugPrint('  Packet (dec) : $packet');
      debugPrint('  Packet (bin) : $binaryStr');
      debugPrint('');
      debugPrint('  ┌─ 4-PPM Chip Sequence ─────────────────────────');
      debugPrint('  │  Mapping: 00→1000  01→0100  10→0010  11→0001');
      debugPrint('  │');

      // Print PPM symbols grouped per byte (4 symbols per byte)
      final symbols = ppmOutput.split(' ');
      int symbolIdx = 0;
      for (int byteIdx = 0; byteIdx < packet.length; byteIdx++) {
        final byteLabel = _formatByteLabel(byteIdx, packet, messageLength);
        final fourSymbols = symbols.sublist(
          symbolIdx,
          (symbolIdx + 4).clamp(0, symbols.length),
        );
        debugPrint('  │  $byteLabel : ${fourSymbols.join(' ')}');
        symbolIdx += 4;
      }

      debugPrint('  └─────────────────────────────────────────────');
      debugPrint('');
      debugPrint('  Total bits in  : ${packet.length * 8}');
      debugPrint('  Total chips out: ${packet.length * 8 * 2}'
          '  (4 chips per 2 bits → 2× expansion)');
      debugPrint('───────────────────────────────────────────────────');
    }

    debugPrint('  ✓ 4-PPM modulation complete');
    debugPrint('═══════════════════════════════════════════════════');
    debugPrint('');
  }

  /// Returns a human-readable label for each byte position in the packet.
  static String _formatByteLabel(
      int byteIdx, List<int> packet, int messageLength) {
    if (byteIdx == 0) return 'Preamble (${_toBinary(packet[byteIdx])})';
    if (byteIdx == 1) return 'Length   (${_toBinary(packet[byteIdx])})';

    final dataEnd = 2 + messageLength;
    if (byteIdx < dataEnd) {
      return 'Data[${byteIdx - 2}]  (${_toBinary(packet[byteIdx])})';
    }
    return 'Parity[${byteIdx - dataEnd}](${_toBinary(packet[byteIdx])})';
  }
}
