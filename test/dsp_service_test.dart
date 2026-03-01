import 'package:flutter_test/flutter_test.dart';

import 'package:bits_blink/reed_solomon/galois_field.dart';
import 'package:bits_blink/reed_solomon/reed_solomon.dart';
import 'package:bits_blink/services/dsp_service.dart';

/// Roundtrip test for the full 4-PPM receiver pipeline.
///
/// Simulates the transmit side (encode → 4-PPM modulate → oversample),
/// then feeds the oversampled bitstring into DSPService and verifies
/// that the original text is recovered.
///
/// Uses samplesPerSlot = 14 for test oversampling (matching original
/// test setup). Production uses 73 for 5ms chips at 480 rows/33ms frame.
const int testSamplesPerSlot = 14;

void main() {
  /// Encode a single byte into its 4-PPM chip string (no spaces).
  String byteTo4Ppm(int byte) {
    const table = {'00': '1000', '01': '0100', '10': '0010', '11': '0001'};
    final bits = byte.toRadixString(2).padLeft(8, '0');
    final buf = StringBuffer();
    for (int i = 0; i < 8; i += 2) {
      buf.write(table[bits.substring(i, i + 2)]);
    }
    return buf.toString();
  }

  /// Oversample a chip string by repeating each character [factor] times.
  String oversample(String chips, int factor) {
    final buf = StringBuffer();
    for (int i = 0; i < chips.length; i++) {
      for (int j = 0; j < factor; j++) {
        buf.write(chips[i]);
      }
    }
    return buf.toString();
  }

  test(
    'Full roundtrip: encode "Hi" → oversample → DSPService → decode "Hi"',
    () {
      // ── Transmit side ──
      initTables();

      const originalText = 'Hi';
      final utf8Bytes = originalText.codeUnits; // [72, 105]
      final messageLength = utf8Bytes.length;

      // RS encode with fixed 8 parity symbols (matching FourPpmService)
      const int rsParityCount = 8;
      final rsEncoded = rsEncodeMessage(utf8Bytes, rsParityCount);

      // Build packet: [SFD=0xAA][SFD=0xAA][length][data+parity][EFD=0x55][EFD=0x55]
      final packet = <int>[0xAA, 0xAA, messageLength, ...rsEncoded, 0x55, 0x55];

      // 4-PPM modulate the entire packet
      final chipsBuf = StringBuffer();
      for (final byte in packet) {
        chipsBuf.write(byteTo4Ppm(byte));
      }
      final cleanChips = chipsBuf.toString();

      // Add some leading zeros (silence before transmission)
      final withSilence = '${'0' * 56}$cleanChips${'0' * 56}';

      // Oversample at the test rate
      final rawBits = oversample(withSilence, testSamplesPerSlot);

      // ── Receive side ──
      String? decoded;
      String? errorMsg;
      bool preambleFound = false;

      final dsp = DSPService(
        samplesPerSlot: testSamplesPerSlot,
        onPreambleFound: (_) => preambleFound = true,
        onPacketDecoded: (text) => decoded = text,
        onError: (msg) => errorMsg = msg,
      );

      // Feed all at once (simulating a very large frame)
      dsp.feedFrame(rawBits);

      // Verify
      expect(preambleFound, isTrue, reason: 'Preamble should have been locked');
      expect(errorMsg, isNull, reason: 'No errors expected: $errorMsg');
      expect(decoded, equals('Hi'), reason: 'Decoded text should be "Hi"');
    },
  );

  test('Preamble hunt across multiple frames', () {
    initTables();

    final utf8Bytes = 'A'.codeUnits; // single byte
    const int rsParityCount = 8;
    final rsEncoded = rsEncodeMessage(utf8Bytes, rsParityCount);
    final packet = <int>[0xAA, 0xAA, 1, ...rsEncoded, 0x55, 0x55];

    final chipsBuf = StringBuffer();
    for (final byte in packet) {
      chipsBuf.write(byteTo4Ppm(byte));
    }
    final cleanChips = chipsBuf.toString();
    final withSilence = '${'0' * 28}$cleanChips${'0' * 28}';

    final rawBits = oversample(withSilence, testSamplesPerSlot);

    // Split into chunks simulating multiple frames (~480 bits each)
    const frameSize = 480;
    final frames = <String>[];
    for (int i = 0; i < rawBits.length; i += frameSize) {
      final end = (i + frameSize).clamp(0, rawBits.length);
      frames.add(rawBits.substring(i, end));
    }

    String? decoded;
    bool preambleFound = false;

    final dsp = DSPService(
      samplesPerSlot: testSamplesPerSlot,
      onPreambleFound: (_) => preambleFound = true,
      onPacketDecoded: (text) => decoded = text,
    );

    for (final frame in frames) {
      dsp.feedFrame(frame);
    }

    expect(preambleFound, isTrue);
    expect(decoded, equals('A'));
  });

  test('Erasure recovery: corrupted symbol → RS corrects it', () {
    initTables();

    final utf8Bytes = 'OK'.codeUnits;
    final messageLength = utf8Bytes.length;
    const int rsParityCount = 8;
    final rsEncoded = rsEncodeMessage(utf8Bytes, rsParityCount);
    final packet = <int>[0xAA, 0xAA, messageLength, ...rsEncoded, 0x55, 0x55];

    final chipsBuf = StringBuffer();
    for (final byte in packet) {
      chipsBuf.write(byteTo4Ppm(byte));
    }
    var cleanChips = chipsBuf.toString();

    // Corrupt one data symbol: replace the first data chip group
    // (after SFD(32) + length(16) = 48 chips) with '0000' (erasure).
    final corruptedChips =
        '${cleanChips.substring(0, 48)}0000${cleanChips.substring(52)}';
    final withSilence = '${'0' * 56}$corruptedChips${'0' * 56}';
    final rawBits = oversample(withSilence, testSamplesPerSlot);

    String? decoded;
    bool preambleFound = false;

    final dsp = DSPService(
      samplesPerSlot: testSamplesPerSlot,
      onPreambleFound: (_) => preambleFound = true,
      onPacketDecoded: (text) => decoded = text,
    );

    dsp.feedFrame(rawBits);

    expect(preambleFound, isTrue);
    expect(
      decoded,
      equals('OK'),
      reason: 'RS should correct the single erasure',
    );
  });
}
