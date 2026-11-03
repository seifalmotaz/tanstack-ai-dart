/// Close information delivered by a socket.
class SocketCloseInfo {
  final int code;
  final String reason;

  const SocketCloseInfo(this.code, [this.reason = '']);

  @override
  String toString() => reason.isEmpty ? '$code' : '$code: $reason';
}

/// Minimal injectable WebSocket surface used by [webSocket].
///
/// Implement this over `dart:io` WebSocket, `package:web_socket_channel`, or a
/// test fake. [messages] yields text frames (and may emit an error when the
/// transport fails). [closed] completes exactly once with the close info.
abstract class WebSocketConnection {
  /// Completes when the handshake finishes; fails with a transport error when
  /// the connection cannot be opened.
  Future<void> get opened;

  /// Inbound text frames for this socket.
  Stream<String> get messages;

  /// Completes when the socket closes, with the close code/reason.
  Future<SocketCloseInfo> get closed;

  /// WHATWG-style ready state: 0 connecting, 1 open, 2 closing, 3 closed.
  int get readyState;

  void send(String data);

  void close([int code = 1000, String reason = '']);
}

/// Creates a socket for [url]. [protocols] is only set when configured.
typedef WebSocketFactory = WebSocketConnection Function(
  Uri url, {
  List<String>? protocols,
});
