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

  /// Start Frame Delimiter byte (0xAA = 170).
  static const int _sfdByte = 0xAA;

  /// End Frame Delimiter byte (0x55 = 85).
  static const int _efdByte = 0x55;

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
    final buffer = StringBuffer();

    for (final byte in packetBytes) {
      final bits = _toBinary(byte); // 8 bits → 4 di-bits → 4 PPM symbols
      for (int i = 0; i < bits.length; i += 2) {
        final diBit = bits.substring(i, i + 2);
        buffer.write(_ppmTable[diBit]);
        buffer.write(' ');
      }
    }

    return buffer.toString().trimRight();
  }

  /// Converts a 4-PPM chip string into a `List<bool>` signal
  /// ('1' → true, '0' → false). Spaces are stripped.
  static List<bool> _chipStringToSignal(String chipStr) {
    return chipStr.replaceAll(' ', '').split('').map((c) => c == '1').toList();
  }

  /// Full pipeline: takes the original text, encodes it (UTF-8 + RS),
  /// builds the final packet, applies 4-PPM modulation, and prints
  /// everything to the debug console.
  static List<bool> encodeAndModulate(String text) {
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

      // Step 2: RS encode with fixed 8 parity symbols
      // (can correct up to 4 errors or 8 erasures)
      const int rsParityCount = 8;
      final rsEncoded = rsEncodeMessage(utf8Bytes, rsParityCount);

      // Step 3: Build final packet — [SFD][SFD][length][data + parity][EFD][EFD]
      final packet = <int>[_sfdByte, _sfdByte, messageLength, ...rsEncoded, _efdByte, _efdByte];

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
      debugPrint(
        '  Total chips out: ${packet.length * 8 * 2}'
        '  (4 chips per 2 bits → 2× expansion)',
      );
      debugPrint('───────────────────────────────────────────────────');
    }

    debugPrint('  ✓ 4-PPM modulation complete');
    debugPrint('═══════════════════════════════════════════════════');
    debugPrint('');

    // Build the signal from all words (single transmission, no redundancy).
    final allChips = <bool>[];
    for (final word in words) {
      final utf8Bytes = utf8.encode(word);
      const int rsParityCount = 8;
      final rsEncoded = rsEncodeMessage(utf8Bytes, rsParityCount);
      final packet = <int>[_sfdByte, _sfdByte, utf8Bytes.length, ...rsEncoded, _efdByte, _efdByte];
      allChips.addAll(_chipStringToSignal(modulateTo4Ppm(packet)));
    }

    debugPrint(
      '  📡 ${allChips.length} total chips '
      '(${(allChips.length * 66 / 1000).toStringAsFixed(1)}s TX time)',
    );

    return allChips;
  }

  static String _formatByteLabel(
    int byteIdx,
    List<int> packet,
    int messageLength,
  ) {
    if (byteIdx <= 1) return 'SFD[$byteIdx]   (${_toBinary(packet[byteIdx])})';
    if (byteIdx == 2) return 'Length   (${_toBinary(packet[byteIdx])})';

    final dataEnd = 3 + messageLength;
    if (byteIdx < dataEnd) {
      return 'Data[${byteIdx - 3}]  (${_toBinary(packet[byteIdx])})';
    }
    final parityEnd = dataEnd + 8;
    if (byteIdx < parityEnd) {
      return 'Parity[${byteIdx - dataEnd}](${_toBinary(packet[byteIdx])})';
    }
    return 'EFD[${byteIdx - parityEnd}]  (${_toBinary(packet[byteIdx])})';
  }
}
