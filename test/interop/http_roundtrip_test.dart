@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tanstack_ai_dart/connections.dart';
import 'package:tanstack_ai_dart/byok.dart' as byok;
import 'package:test/test.dart';

const context = RunAgentInputContext(threadId: 'thread', runId: 'run');
const input = <Map<String, dynamic>>[
  {
    'id': 'user',
    'role': 'user',
    'parts': [
      {'type': 'text', 'content': 'hello'}
    ]
  },
];

Future<HttpServer> serve(void Function(HttpRequest) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  addTearDown(() => server.close(force: true));
  return server;
}

String endpoint(HttpServer server) => 'http://127.0.0.1:${server.port}/chat';

void main() {
  test('HTTP BYOK errors use the same public type as the keyring client',
      () async {
    final server = await serve((request) async {
      await request.drain<void>();
      request.response.statusCode = 401;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': {
          'type': 'byok_missing',
          'provider': 'custom',
          'message': 'Missing custom API key'
        },
      }));
      await request.response.close();
    });
    final connection = fetchServerSentEvents(endpoint(server));
    await expectLater(connection.connect!(input, runContext: context).toList(),
        throwsA(isA<byok.ByokMissingError>()));
  });
  test('real SSE reconnect deduplicates and drains later agent iterations',
      () async {
    final requests = <Map<String, dynamic>>[];
    final offsets = <String?>[];
    final server = await serve((request) async {
      requests.add(jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>);
      offsets.add(request.headers.value('Last-Event-ID'));
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      void event(int id, Map<String, dynamic> chunk) =>
          request.response.write('id: $id\ndata: ${jsonEncode(chunk)}\n\n');
      if (requests.length == 1) {
        event(1, {'type': 'RUN_STARTED', 'runId': 'run', 'threadId': 'thread'});
        event(2,
            {'type': 'TEXT_MESSAGE_CONTENT', 'messageId': 'a', 'delta': 'Cai'});
      } else {
        event(2,
            {'type': 'TEXT_MESSAGE_CONTENT', 'messageId': 'a', 'delta': 'Cai'});
        event(3,
            {'type': 'TEXT_MESSAGE_CONTENT', 'messageId': 'a', 'delta': 'ro'});
        event(
            4, {'type': 'RUN_FINISHED', 'runId': 'run', 'threadId': 'thread'});
        event(5, {
          'type': 'TOOL_CALL_RESULT',
          'toolCallId': 'tc',
          'content': 'after iteration'
        });
        event(
            6, {'type': 'RUN_FINISHED', 'runId': 'run', 'threadId': 'thread'});
      }
      await request.response.close();
    });
    final connection = fetchServerSentEvents(
        endpoint(server),
        const FetchConnectionOptions(
            reconnect: ReconnectOptions(delay: Duration.zero)));
    final chunks = await connection.connect!(input, runContext: context)
        .toList()
        .timeout(const Duration(seconds: 5));
    expect(offsets, [null, '2']);
    expect(
        chunks
            .where((chunk) => chunk['type'] == 'TEXT_MESSAGE_CONTENT')
            .map((chunk) => chunk['delta'])
            .join(),
        'Cairo');
    expect(chunks.any((chunk) => chunk['type'] == 'TOOL_CALL_RESULT'), isTrue);
    expect(requests.first['messages'], [
      {'id': 'user', 'role': 'user', 'content': 'hello'},
    ]);
    expect(requests.last['runId'], 'run');
  });

  test('real JSON polling retains run identity and keeps BYOK headers on POST',
      () async {
    final calls = <String>[];
    final server = await serve((request) async {
      calls.add(request.method);
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'POST') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['runId'], 'run');
        expect(request.headers.value('x-byok-custom'), 'test-only-key');
        request.response.write(jsonEncode({
          'chunks': [
            {'type': 'RUN_STARTED', 'threadId': 'thread', 'runId': 'run'}
          ],
          'offset': 'one',
          'done': false,
        }));
      } else {
        expect(request.uri.queryParameters, {'runId': 'run', 'offset': 'one'});
        expect(request.headers.value('x-byok-custom'), isNull);
        request.response.write(jsonEncode({
          'chunks': [
            {'type': 'RUN_FINISHED', 'threadId': 'thread', 'runId': 'run'}
          ],
          'offset': 'two',
          'done': true,
        }));
      }
      await request.response.close();
    });
    final connection = fetchJson(
        endpoint(server), const FetchJsonOptions(pollInterval: Duration.zero));
    final chunks = await connection.connect!(input,
            runContext: const RunAgentInputContext(
                threadId: 'thread',
                runId: 'run',
                headers: {'x-byok-custom': 'test-only-key'}))
        .toList()
        .timeout(const Duration(seconds: 5));
    expect(calls, ['POST', 'GET']);
    expect(
        chunks.map((chunk) => chunk['type']), ['RUN_STARTED', 'RUN_FINISHED']);
  });

  test('cancels a real HTTP request while response headers are still pending',
      () async {
    final arrived = Completer<void>();
    final server = await serve((request) {
      arrived.complete();
    });
    final cancellation = CancellationController();
    final ended = Completer<void>();
    final connection = fetchServerSentEvents(endpoint(server));
    final subscription = connection.connect!
            (input, signal: cancellation.signal, runContext: context)
        .listen((_) {}, onError: (Object error) {
      if (!ended.isCompleted) ended.completeError(error);
    }, onDone: () {
      if (!ended.isCompleted) ended.complete();
    });
    addTearDown(() {
      unawaited(subscription.cancel());
    });
    await arrived.future.timeout(const Duration(seconds: 2));
    cancellation.cancel();
    await ended.future.timeout(const Duration(seconds: 1));
  });
}
