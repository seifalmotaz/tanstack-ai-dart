// Ported from packages/ai-client/tests/response-stream.ts behaviors and the
// JS-runtime gaps called out by connection-adapters.test.ts.
import 'dart:async';
import 'dart:convert';

import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  test('should handle missing response body', () {
    expect(
      () => requireResponseBody(null),
      throwsA(
        isA<UnsupportedResponseStreamError>().having(
            (error) => error.missingFeature,
            'missingFeature',
            UnsupportedResponseStreamError.responseBody),
      ),
    );
  });

  test(
      'should throw an actionable unsupported-stream error when getReader is '
      'missing', () {
    const error = UnsupportedResponseStreamError(
      UnsupportedResponseStreamError.responseBodyGetReader,
    );
    expect(error.missingFeature, 'Response.body.getReader');
    expect(error.toString(), contains('streaming chunks'));
  });

  test(
      'should throw an actionable unsupported-stream error when TextDecoder '
      'is missing', () {
    const error = UnsupportedResponseStreamError(
      UnsupportedResponseStreamError.textDecoder,
    );
    expect(error.missingFeature, 'TextDecoder');
    expect(error.toString(), contains('TextDecoder'));
  });

  test('replacement-mode decode flushes a mid-multibyte EOF into truncation',
      () async {
    // "€" is E2 82 AC. Cut after E2 82 with no newline: JS TextDecoder emits
    // U+FFFD, leaving a non-empty trailing buffer -> StreamTruncatedError.
    final bytes = <int>[0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0xE2, 0x82];
    await expectLater(
      readResponseLines(Stream<List<int>>.value(bytes)).toList(),
      throwsA(isA<StreamTruncatedError>()),
    );
  });

  test('decodes a multibyte character split across chunks', () async {
    final bytes = utf8.encode('data: مرحبا\n');
    final lines = readResponseLines(
      Stream<List<int>>.fromIterable([
        bytes.sublist(0, 8),
        bytes.sublist(8),
      ]),
    ).toList();
    expect(await lines, ['data: مرحبا']);
  });

  test('normalizes CRLF and ignores blank lines', () async {
    final lines = await readResponseLines(
      Stream<List<int>>.value(utf8.encode('data: a\r\n\r\ndata: b\n')),
    ).toList();
    expect(lines, ['data: a', 'data: b']);
  });

  test('throws StreamTruncatedError on a non-empty trailing line', () async {
    await expectLater(
      readResponseLines(
        Stream<List<int>>.value(utf8.encode('data: {"x":1}')),
      ).toList(),
      throwsA(isA<StreamTruncatedError>()),
    );
  });

  test('cancellation releases the response stream', () async {
    final controller = CancellationController();
    final response = ControlledResponse();
    final lines = readResponseLines(
      response.response.stream,
      signal: controller.signal,
    );
    final future = lines.toList();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    controller.cancel();
    expect(await future, isEmpty);
    expect(response.cancelled, isTrue);
  });
}
