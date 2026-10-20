// Ported from packages/ai-client/tests/sse-done-model.test.ts
import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  test(
      'SSE [DONE] synthetic RUN_FINISHED copies metadata.tanstack.model from '
      'RUN_STARTED and sets finishReason stop', () async {
    final body = '${sseData(
      '{"type":"RUN_STARTED","runId":"r","threadId":"t",'
      '"metadata":{"tanstack":{"model":"gpt-test"}}}',
    )}data: [DONE]\n\n';
    final client = FakeHttpClient((_) async => rawResponse(body));
    final adapter = fetchServerSentEvents(
      '/api/chat',
      FetchConnectionOptions(client: client),
    );

    final chunks = await collect(
      adapter.connect!(
        [],
        runContext: const RunAgentInputContext(threadId: 't', runId: 'r'),
      ),
    );

    expect(chunks, hasLength(2));
    final finished = chunks.last;
    expect(finished['type'], 'RUN_FINISHED');
    final tanstack = (finished['metadata'] as Map)['tanstack'] as Map;
    expect(tanstack['model'], 'gpt-test');
    expect(tanstack['finishReason'], 'stop');
  });
}
