/// Represents a single chat message in the BITSBlink interface.
class Message {
  final String text;
  final String timestamp;
  final bool isSentByMe;
  final String senderName;

  const Message({
    required this.text,
    required this.timestamp,
    required this.isSentByMe,
    required this.senderName,
  });

  /// Creates a new sent message stamped with the current time.
  factory Message.sent(String text) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');

    return Message(
      text: text,
      timestamp: '$hh:$mm:$ss',
      isSentByMe: true,
      senderName: 'Surface',
    );
  }
}
