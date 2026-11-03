// Ported from packages/ai-client/tests/sse-parser-cleanup.test.ts
// The GenerationClient-specific assertions are exercised through
// parseSseResponse here; GenerationClient itself is owned by another worker.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

String frame(Map<String, dynamic> chunk) => sseData(jsonEncode(chunk));

void main() {
  for (final behavior in ['resolves', 'throws', 'rejects', 'never settles']) {
    test(
        'cancels a generation response on early return when cancellation '
        '$behavior', () async {
      final response = ControlledResponse(() {
        if (behavior == 'throws') throw StateError('cleanup failed');
        if (behavior == 'rejects') {
          return Future<void>.error(StateError('cleanup failed'));
        }
        if (behavior == 'never settles') return Completer<void>().future;
      });
      response.write(frame({'type': 'RUN_STARTED', 'runId': 'run'}));
      final iterator = StreamIterator<StreamChunk>(
        parseSseResponse(response.response),
      );

      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current, {'type': 'RUN_STARTED', 'runId': 'run'});
      await iterator.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(response.cancelled, isTrue);
    });
  }

  test('reports a generation error without waiting for custom cancellation',
      () async {
    final response = ControlledResponse();
    final chunksFuture = parseSseResponse(response.response).toList();
    response
        .write(frame({'type': 'RUN_ERROR', 'message': 'generation failed'}));
    await response.close();
    final chunks = await chunksFuture;
    expect(chunks.single['type'], 'RUN_ERROR');
    expect(chunks.single['message'], 'generation failed');
    await Future<void>.delayed(Duration.zero);
    expect(response.cancelled, isTrue);
  });

  test('preserves generation reader errors and releases the lock', () async {
    final error = StateError('response reader failed');
    final response = http.StreamedResponse(Stream<List<int>>.error(error), 200);
    await expectLater(
      parseSseResponse(response).toList(),
      throwsA(same(error)),
    );
  });

  test(
      'drains generation EOF and keeps ignoring malformed JSON and DONE '
      'markers', () async {
    final warnings = <String>[];
    final response = ControlledResponse();
    final chunksFuture = parseSseResponse(
      response.response,
      onWarning: warnings.add,
    ).toList();
    response.write(
      'data: {invalid json}\n\n'
      'data: [DONE]\n\n'
      '${frame({'type': 'RUN_STARTED', 'runId': 'run'})}',
    );
    await response.close();
    final chunks = await chunksFuture;

    expect(chunks, [
      {'type': 'RUN_STARTED', 'runId': 'run'},
    ]);
    expect(warnings, hasLength(2));
  });
}
