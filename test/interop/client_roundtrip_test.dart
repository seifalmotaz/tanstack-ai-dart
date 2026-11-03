@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as connections;
import 'package:tanstack_ai_dart/generation.dart' as generation;
import 'package:test/test.dart';

Future<HttpServer> _server(void Function(HttpRequest) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  addTearDown(() => server.close(force: true));
  return server;
}

String _url(HttpServer server) => 'http://127.0.0.1:${server.port}/ai';

void _event(HttpResponse response, Map<String, dynamic> chunk) =>
    response.write('data: ${jsonEncode(chunk)}\n\n');

void main() {
  test(
      'public chat adapter awaits the run and preserves concurrent server identities',
      () async {
    final bodies = <Map<String, dynamic>>[];
    final server = await _server((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      bodies.add(body);
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      _event(request.response, {
        'type': 'RUN_STARTED',
        'runId': body['runId'],
        'threadId': body['threadId']
      });
      if (bodies.length == 1) {
        for (final chunk in [
          {
            'type': 'TEXT_MESSAGE_START',
            'messageId': 'server-a1',
            'role': 'assistant'
          },
          {
            'type': 'TEXT_MESSAGE_CONTENT',
            'messageId': 'server-a1',
            'delta': 'First '
          },
          {
            'type': 'TEXT_MESSAGE_START',
            'messageId': 'server-a2',
            'role': 'assistant'
          },
          {
            'type': 'TEXT_MESSAGE_CONTENT',
            'messageId': 'server-a2',
            'delta': 'Second'
          },
          {
            'type': 'TEXT_MESSAGE_CONTENT',
            'messageId': 'server-a1',
            'delta': 'answer'
          },
          {'type': 'TEXT_MESSAGE_END', 'messageId': 'server-a1'},
          {'type': 'TEXT_MESSAGE_END', 'messageId': 'server-a2'},
        ]) {
          _event(request.response, chunk);
        }
      } else {
        _event(request.response, {
          'type': 'TEXT_MESSAGE_START',
          'messageId': 'server-a3',
          'role': 'assistant'
        });
        _event(request.response, {
          'type': 'TEXT_MESSAGE_CONTENT',
          'messageId': 'server-a3',
          'delta': 'Follow-up'
        });
        _event(request.response,
            {'type': 'TEXT_MESSAGE_END', 'messageId': 'server-a3'});
      }
      _event(request.response, {
        'type': 'RUN_FINISHED',
        'runId': body['runId'],
        'threadId': body['threadId']
      });
      await request.response.close();
    });
    final client = ChatClient(
      connection: connections.fetchServerSentEvents(_url(server)),
      threadId: 'chat-thread',
      context: {'secretToken': 'local-only-test-marker'},
    );
    addTearDown(client.dispose);
    await client.sendMessage('hello').timeout(const Duration(seconds: 5));
    expect(client.getIsLoading(), isFalse);
    expect(client.getError(), isNull);
    final assistants = client
        .getMessages()
        .where((message) => message.role == 'assistant')
        .toList();
    expect(assistants.map((message) => message.id), ['server-a1', 'server-a2']);
    expect(assistants.map((message) => message.answer),
        ['First answer', 'Second']);
    await client.sendMessage('continue').timeout(const Duration(seconds: 5));
    expect(bodies.length, 2);
    expect(jsonEncode(bodies), isNot(contains('local-only-test-marker')));
    expect(
        (bodies.last['messages'] as List)
            .map((dynamic message) => message['id']),
        containsAllInOrder(['server-a1', 'server-a2']));
    expect(client.getMessages().last.answer, 'Follow-up');
  });

  test('the same public HTTP adapter plugs directly into generation', () async {
    final server = await _server((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(body['threadId'], 'generation-thread');
      expect(body['forwardedProps'], containsPair('prompt', 'Summarize'));
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      _event(request.response, {
        'type': 'RUN_STARTED',
        'threadId': 'generation-thread',
        'runId': body['runId']
      });
      _event(request.response, {
        'type': 'CUSTOM',
        'name': 'generation:progress',
        'value': {'progress': 50, 'message': 'Working'}
      });
      _event(request.response, {
        'type': 'CUSTOM',
        'name': 'generation:result',
        'value': {'summary': 'Complete'}
      });
      _event(request.response, {
        'type': 'RUN_FINISHED',
        'threadId': 'generation-thread',
        'runId': body['runId']
      });
      await request.response.close();
    });
    final progress = <num>[];
    final client = generation.GenerationClient<Map<String, dynamic>,
        Map<String, dynamic>, Map<String, dynamic>>(
      threadId: 'generation-thread',
      connection: connections.fetchServerSentEvents(_url(server)),
      onProgress: (value, _) => progress.add(value),
    );
    addTearDown(client.dispose);
    await client
        .generate({'prompt': 'Summarize'}).timeout(const Duration(seconds: 5));
    expect(client.getResult(), {'summary': 'Complete'});
    expect(client.getSnapshot().isLoading, isFalse);
    expect(client.getSnapshot().error, isNull);
    expect(
        client.getSnapshot().status, generation.GenerationClientState.success);
    expect(progress, [50]);
  });
}
