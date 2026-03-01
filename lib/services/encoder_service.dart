import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../reed_solomon/galois_field.dart';
import '../reed_solomon/reed_solomon.dart';

/// Start Frame Delimiter byte (0xAA = 170).
const int _sfdByte = 0xAA;

/// End Frame Delimiter byte (0x55 = 85).
const int _efdByte = 0x55;

/// Service that converts text into UTF-8 binary and applies
/// Reed-Solomon encoding to each word with 1:1 parity ratio.
class EncoderService {
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

  /// Encodes a message: splits into words, converts each word to
  /// UTF-8 bytes, RS-encodes with 1:1 parity, prepends preamble +
  /// length, and prints everything including final binary form.
  static void encodeAndPrint(String text) {
    _ensureInit();

    final words = text.split(RegExp(r'\s+'));
    debugPrint('═══════════════════════════════════════════');
    debugPrint('  BITSBlink Encoder Pipeline');
    debugPrint('═══════════════════════════════════════════');
    debugPrint('  Original : "$text"');
    debugPrint('  Words    : $words');
    debugPrint('───────────────────────────────────────────');

    for (final word in words) {
      // Step 1: UTF-8 encode
      final utf8Bytes = utf8.encode(word);
      final messageLength = utf8Bytes.length;

      // Step 2: RS encode with 1:1 parity (nsym = message length)
      final rsEncoded = rsEncodeMessage(utf8Bytes, messageLength);
      final parity = rsEncoded.sublist(messageLength);

      // Step 3: Build final packet — [SFD][SFD][length][data + parity][EFD][EFD]
      final packet = <int>[_sfdByte, _sfdByte, messageLength, ...rsEncoded, _efdByte, _efdByte];

      // Step 4: Convert to binary
      final binaryStr = packet.map(_toBinary).join(' ');

      debugPrint('  Word       : "$word"');
      debugPrint('  UTF-8      : $utf8Bytes');
      debugPrint('  RS Parity  : $parity  (${parity.length} symbols)');
      debugPrint('  SFD        : 0xAA 0xAA (${_toBinary(_sfdByte)} ${_toBinary(_sfdByte)})');
      debugPrint('  Length     : $messageLength bytes');
      debugPrint('  Packet     : $packet');
      debugPrint('  Binary     : $binaryStr');
      debugPrint('───────────────────────────────────────────');
    }

    debugPrint('  ✓ Transmission ready');
    debugPrint('═══════════════════════════════════════════');
  }
}
