// Ported from packages/ai-client/tests/fetch-json.test.ts
// Test names and groups intentionally mirror the upstream file.
import 'package:http/http.dart' as http;
import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

final messages = <WireMessage>[
  {
    'id': 'msg-1',
    'role': 'user',
    'parts': [
      {'type': 'text', 'content': 'Hi'},
    ],
  },
];

const runContext = RunAgentInputContext(
  threadId: 'thread-1',
  runId: 'run-1',
  headers: {'X-Byok': 'key-1'},
);

Map<String, dynamic> wireFinishedChunk() => {
      'type': 'RUN_FINISHED',
      'threadId': 'thread-1',
      'runId': 'run-1',
      'timestamp': 0,
      'usage': [
        {'inputTokens': 3, 'outputTokens': 5, 'totalTokens': 8},
      ],
      'metadata': {
        'tanstack': {'finishReason': 'stop'},
      },
    };

class RequestView {
  final String url;
  final String method;
  final Map<String, String> headers;
  final Map<String, dynamic>? body;

  RequestView(http.BaseRequest request)
      : url = request.url.toString(),
        method = request.method,
        headers = request.headers,
        body = request is http.Request && request.body.trim().isNotEmpty
            ? jsonBodyOf(request)
            : null;
}

RequestView requestAt(FakeHttpClient client, int index) =>
    RequestView(client.requests[index]);

List<String> requestedUrls(FakeHttpClient client) =>
    client.requests.map((request) => request.url.toString()).toList();

FakeHttpClient sequence(List<Object> steps) {
  return FakeHttpClient((_) async {
    if (steps.isEmpty) throw StateError('unexpected extra request');
    final step = steps.removeAt(0);
    if (step is! http.StreamedResponse) {
      throw step;
    }
    return step;
  });
}

Stream<StreamChunk> connectWith(
  FakeHttpClient client, {
  CancellationSignal? signal,
  Duration pollInterval = Duration.zero,
}) {
  final adapter = fetchJson(
    '/api/chat',
    FetchJsonOptions(
      client: client,
      pollInterval: pollInterval,
      reconnect: const ReconnectOptions(delay: Duration.zero),
    ),
  );
  return adapter.connect!(
    messages,
    signal: signal,
    runContext: runContext,
  );
}

void main() {
  group('fetchJson', () {
    test(
        'POSTs the same body and headers as fetchHttpStream, plus '
        'Accept: application/json', () async {
      final jsonClient = sequence([
        jsonResponse({'chunks': <Object>[], 'done': true}),
      ]);
      final streamClient = sequence([rawResponse('')]);
      const headers = {'Authorization': 'Bearer token'};
      const body = {'model': 'gpt-5.5'};

      await collect(
        fetchJson(
          '/api/chat',
          FetchJsonOptions(client: jsonClient, headers: headers, body: body),
        ).connect!(messages, data: {'extra': 1}, runContext: runContext),
      );
      await collect(
        fetchHttpStream(
          '/api/chat',
          FetchConnectionOptions(
            client: streamClient,
            headers: headers,
            body: body,
          ),
        ).connect!(messages, data: {'extra': 1}, runContext: runContext),
      );

      final json = requestAt(jsonClient, 0);
      final stream = requestAt(streamClient, 0);
      expect(json.url, '/api/chat');
      expect(json.method, 'POST');
      expect(json.body, stream.body);
      expect(json.body, containsPair('threadId', 'thread-1'));
      expect(json.body, containsPair('runId', 'run-1'));
      expect(json.body?['forwardedProps'], {
        'model': 'gpt-5.5',
        'extra': 1,
      });
      expect(json.headers['Accept'], 'application/json');
      expect(json.headers['Content-Type'], 'application/json');
      expect(json.headers['Authorization'], 'Bearer token');
      expect(json.headers['X-Byok'], 'key-1');
      expect(json.headers['X-Run-Id'], 'run-1');
      expect(stream.headers['X-Run-Id'], 'run-1');
    });

    test('restores usage and extras on each chunk, in order', () async {
      final client = sequence([
        jsonResponse({
          'chunks': [contentChunk('Hello'), wireFinishedChunk()],
          'done': true,
        }),
      ]);

      final chunks = await collect(connectWith(client));

      expect(chunks.map((chunk) => chunk['type']), [
        'TEXT_MESSAGE_CONTENT',
        'RUN_FINISHED',
      ]);
      final finished = chunks[1];
      expect(finished['finishReason'], 'stop');
      expect(finished['usage'], {
        'promptTokens': 3,
        'completionTokens': 5,
        'totalTokens': 8,
      });
    });

    test('polls GET ?runId&offset until done: true, with no duplicate chunks',
        () async {
      final client = sequence([
        jsonResponse({
          'chunks': [contentChunk('a')],
          'offset': '1',
          'done': false,
        }),
        jsonResponse({'chunks': <Object>[], 'offset': '1', 'done': false}),
        jsonResponse({
          'chunks': [contentChunk('b')],
          'offset': '2',
          'done': false,
        }),
        jsonResponse({
          'chunks': [contentChunk('c'), wireFinishedChunk()],
          'offset': '4',
          'done': true,
        }),
      ]);

      final chunks = await collect(connectWith(client));

      expect(deltasOf(chunks), ['a', 'b', 'c']);
      expect(chunks, hasLength(4));
      expect(requestedUrls(client), [
        '/api/chat',
        '/api/chat?runId=run-1&offset=1',
        '/api/chat?runId=run-1&offset=1',
        '/api/chat?runId=run-1&offset=2',
      ]);
      expect(requestAt(client, 1).method, 'GET');
      expect(requestAt(client, 1).headers['Accept'], 'application/json');
    });

    test('throws the HTTP status on a non-2xx reply', () async {
      final client = sequence([
        rawResponse(
          'upstream down',
          status: 502,
          reasonPhrase: 'Bad Gateway',
        ),
      ]);

      await expectLater(
        collect(connectWith(client)),
        throwsA(
          predicate<Object>(
            (error) =>
                error.toString() == 'HTTP error! status: 502 Bad Gateway',
          ),
        ),
      );
    });

    test(
        'throws a clear error, not a FormatException, when the body is not '
        'JSON', () async {
      final client = sequence([
        rawResponse(
          '<html><body>Proxy error</body></html>',
          headers: const {'content-type': 'text/html'},
        ),
      ]);

      final error = await captureError(() => collect(connectWith(client)));

      expect(error, isA<FetchJsonException>());
      expect(error, isNot(isA<FormatException>()));
      expect(
        error.toString(),
        contains('not JSON (content-type: text/html)'),
      );
    });

    test('throws a clear error when the JSON body has the wrong shape',
        () async {
      final client = sequence([
        jsonResponse({'messages': <Object>[]}),
      ]);

      await expectLater(
        collect(connectWith(client)),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('{ chunks, done, offset? }'),
          ),
        ),
      );
    });

    test('throws when done: false has no offset to resume from', () async {
      final client = sequence([
        jsonResponse({
          'chunks': [contentChunk('a')],
          'done': false,
        }),
      ]);

      await expectLater(
        collect(connectWith(client)),
        throwsA(
          predicate<Object>(
            (error) =>
                error.toString().contains('done: false without an offset'),
          ),
        ),
      );
    });

    test('retries a failed poll', () async {
      final client = sequence([
        jsonResponse({
          'chunks': [contentChunk('a')],
          'offset': '1',
          'done': false,
        }),
        StateError('Failed to fetch'),
        jsonResponse({
          'chunks': [contentChunk('b')],
          'offset': '2',
          'done': true,
        }),
      ]);

      final chunks = await collect(connectWith(client));

      expect(deltasOf(chunks), ['a', 'b']);
      expect(requestedUrls(client), [
        '/api/chat',
        '/api/chat?runId=run-1&offset=1',
        '/api/chat?runId=run-1&offset=1',
      ]);
    });

    test('gives up on a poll after the reconnect ceiling', () async {
      final client = sequence([
        jsonResponse({'chunks': <Object>[], 'offset': '1', 'done': false}),
        StateError('Failed to fetch'),
        StateError('Failed to fetch'),
      ]);
      final adapter = fetchJson(
        '/api/chat',
        FetchJsonOptions(
          client: client,
          pollInterval: Duration.zero,
          reconnect: const ReconnectOptions(
            maxAttempts: 1,
            delay: Duration.zero,
          ),
        ),
      );

      await expectLater(
        collect(adapter.connect!(
          messages,
          runContext: runContext,
        )),
        throwsA(isA<StreamReconnectLimitError>()),
      );
      expect(client.requests, hasLength(3));
    });

    test('does not retry a failed first POST', () async {
      final networkError = StateError('Failed to fetch');
      final client = sequence([
        networkError,
        jsonResponse({'chunks': <Object>[], 'done': true}),
      ]);

      await expectLater(
        collect(connectWith(client)),
        throwsA(
          predicate<Object>(
            (error) => error is StreamReadError && error.cause == networkError,
          ),
        ),
      );
      expect(client.requests, hasLength(1));
    });

    test(
        'ends at once with no further request when stopped during the poll '
        'delay', () async {
      final client = sequence([
        jsonResponse({
          'chunks': [contentChunk('a')],
          'offset': '1',
          'done': false,
        }),
        jsonResponse({
          'chunks': [contentChunk('b')],
          'offset': '2',
          'done': true,
        }),
      ]);
      final controller = CancellationController();
      final timer = Future<void>.delayed(
        const Duration(milliseconds: 20),
        controller.cancel,
      );

      final chunks = await collect(
        connectWith(
          client,
          signal: controller.signal,
          pollInterval: const Duration(seconds: 60),
        ),
      );
      await timer;

      expect(deltasOf(chunks), ['a']);
      expect(client.requests, hasLength(1));
    });

    test('joinRun starts with GET ?runId&offset=-1', () async {
      final client = sequence([
        jsonResponse({
          'chunks': [contentChunk('a')],
          'offset': '1',
          'done': false,
        }),
        jsonResponse({
          'chunks': [contentChunk('b')],
          'offset': '2',
          'done': true,
        }),
      ]);
      final adapter = fetchJson(
        '/api/chat',
        FetchJsonOptions(client: client, pollInterval: Duration.zero),
      );

      final chunks = await collect(adapter.joinRun!('run-9'));

      expect(deltasOf(chunks), ['a', 'b']);
      expect(requestAt(client, 0).method, 'GET');
      expect(requestedUrls(client), [
        '/api/chat?runId=run-9&offset=-1',
        '/api/chat?runId=run-9&offset=1',
      ]);
    });

    test('hydrate GETs ?threadId', () async {
      final client = sequence([
        jsonResponse({
          'messages': <Object>[],
          'activeRun': {'runId': 'run-3'},
        }),
      ]);
      final adapter = fetchJson(
        '/api/chat',
        FetchJsonOptions(client: client),
      );

      final result = await adapter.hydrate!('thread-1');

      expect(result.activeRun?.runId, 'run-3');
      expect(requestedUrls(client), ['/api/chat?threadId=thread-1']);
    });
  });
}
