import 'dart:convert';

import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

void main() {
  group('SseFrameParser', () {
    test('handles UTF-8 split across arbitrary byte boundaries', () {
      final parser = SseFrameParser();
      final bytes = utf8.encode(
        'data: {"type":"TEXT_MESSAGE_CONTENT","delta":"مرحبا"}\n\n',
      );
      final frames = <String>[];
      for (final byte in bytes) {
        frames.addAll(parser.add([byte]));
      }
      frames.addAll(parser.finish());

      expect(frames, ['{"type":"TEXT_MESSAGE_CONTENT","delta":"مرحبا"}']);
      expect(jsonDecode(frames.single), {
        'type': 'TEXT_MESSAGE_CONTENT',
        'delta': 'مرحبا',
      });
    });

    test('CRLF, comments, id/event fields and multiline data', () {
      final parser = SseFrameParser();
      final frames = parser.add(
        utf8.encode(
          'id: 1\r\n'
          'event: custom\r\n'
          ': keep-alive\r\n'
          'data: {"type":"CUSTOM",\r\n'
          'data: "name":"approval-requested",\r\n'
          'data: "value":{}}\r\n'
          '\r\n'
          'data: [DONE]\r\n'
          '\r\n',
        ),
      );

      expect(frames.length, 2);
      expect(frames[0], contains('"name":"approval-requested"'));
      expect(frames[0], contains('\n'));
      expect(jsonDecode(frames[0]), {
        'type': 'CUSTOM',
        'name': 'approval-requested',
        'value': <String, dynamic>{},
      });
      expect(frames[1], '[DONE]');
    });

    test('blank event frames are ignored', () {
      final parser = SseFrameParser();
      final frames = parser.add(
        utf8.encode('\n\n: comment only\n\nevent: ping\n\n'),
      );
      expect(frames, isEmpty);
    });

    test('lone CR line endings terminate lines and frames', () {
      final parser = SseFrameParser();
      final frames = parser.add(
        utf8.encode(
          'data: {"type":"A"}\r\r'
          'event: ignored\r'
          'data: {"type":"B"}\r\r',
        ),
      );
      expect(frames, ['{"type":"A"}', '{"type":"B"}']);
    });

    test('CRLF split across chunks is treated as one line ending', () {
      final parser = SseFrameParser();
      final frames = <String>[];
      frames.addAll(parser.add(utf8.encode('data: {"type":"A"}\r')));
      frames.addAll(
        parser.add(utf8.encode('\n\r\ndata: {"type":"B"}\r\n\r\n')),
      );
      expect(frames, ['{"type":"A"}', '{"type":"B"}']);
    });

    test('leading UTF-8 BOM is stripped, even when split across chunks', () {
      final parser = SseFrameParser();
      final bytes = utf8.encode('\uFEFFdata: {"type":"A"}\r\r');
      final frames = <String>[];
      for (final byte in bytes) {
        frames.addAll(parser.add([byte]));
      }
      expect(frames, ['{"type":"A"}']);
    });

    test('finish flushes a frame without a trailing blank line', () {
      final parser = SseFrameParser();
      expect(parser.add(utf8.encode('data: {"type":"RUN_FINISHED"}')), isEmpty);
      expect(parser.finish(), ['{"type":"RUN_FINISHED"}']);
      expect(parser.finish(), isEmpty);
    });
  });
}
