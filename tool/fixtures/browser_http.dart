@TestOn('browser')
library;

import 'dart:async';
import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

const endpoint = 'BROWSER_HTTP_ENDPOINT';

Future<List<StreamChunk>> request(String path, {bool credentials = true}) {
  final adapter = xhrServerSentEvents(
      '$endpoint/$path', XhrConnectionOptions(withCredentials: credentials));
  return adapter.connect!([],
          runContext:
              const RunAgentInputContext(threadId: 'browser', runId: 'run'))
      .toList();
}

void main() {
  test(
      'real browser XHR streams Arabic and sends cookies only with credentials',
      () async {
    await request('set-cookie');
    final included = await request('echo-cookie');
    expect(included.first['cookie'], contains('sdk-browser=test'));
    expect(included.first['text'], 'عميل مصري 🏡');
    final omitted = await request('echo-cookie', credentials: false);
    expect(omitted.first['cookie'], isEmpty);
  });
  test('real browser XHR aborts before headers', () async {
    final cancellation = CancellationController();
    final stream = xhrServerSentEvents('$endpoint/slow').connect!([],
        signal: cancellation.signal,
        runContext:
            const RunAgentInputContext(threadId: 'browser', runId: 'abort'));
    final completed = stream.toList();
    Timer(const Duration(milliseconds: 40), cancellation.cancel);
    try {
      await completed.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      fail('Browser XHR did not abort');
    } catch (_) {
      expect(cancellation.signal.isAborted, isTrue);
    }
  });
}
