import 'dart:convert';

/// Incremental Server-Sent Events frame parser.
///
/// Only the `data` field is surfaced. `event`, `id`, `retry`, comments, and
/// blank frames are ignored. Multiple `data:` lines in one frame are joined
/// with `\n`, matching the WHATWG event-stream format. Raw bytes are buffered
/// per line and decoded only once a full line is available, so a UTF-8
/// sequence split across network chunks is handled correctly. LF, CRLF, and
/// lone CR line endings are accepted, as is an optional UTF-8 BOM at the very
/// start of the stream.
///
/// Feed chunks with [add]. Each returned string is one event's data payload
/// (`[DONE]` is returned as-is). Call [finish] when the byte stream ends to
/// flush a final frame that was not followed by a blank line.
class SseFrameParser {
  final List<int> _lineBytes = <int>[];
  final List<String> _data = <String>[];
  bool _sawData = false;
  bool _skipLf = false;
  bool _firstLine = true;

  List<String> add(List<int> bytes) {
    final out = <String>[];
    for (final byte in bytes) {
      if (_skipLf) {
        _skipLf = false;
        if (byte == 0x0A) continue;
      }
      if (byte == 0x0D) {
        _consumeLine(_decodeLine(), out);
        _skipLf = true;
      } else if (byte == 0x0A) {
        _consumeLine(_decodeLine(), out);
      } else {
        _lineBytes.add(byte);
      }
    }
    return out;
  }

  List<String> finish() {
    final out = <String>[];
    if (_lineBytes.isNotEmpty) {
      _consumeLine(_decodeLine(), out);
    }
    _dispatch(out);
    return out;
  }

  String _decodeLine() {
    var line = utf8.decode(_lineBytes);
    _lineBytes.clear();
    if (_firstLine) {
      _firstLine = false;
      if (line.startsWith('\uFEFF')) line = line.substring(1);
    }
    return line;
  }

  void _consumeLine(String line, List<String> out) {
    if (line.isEmpty) {
      _dispatch(out);
      return;
    }
    if (line.startsWith(':')) return;

    final colon = line.indexOf(':');
    final field = colon == -1 ? line : line.substring(0, colon);
    var value = colon == -1 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);

    if (field == 'data') {
      _data.add(value);
      _sawData = true;
    }
  }

  void _dispatch(List<String> out) {
    if (_sawData) out.add(_data.join('\n'));
    _data.clear();
    _sawData = false;
  }
}
