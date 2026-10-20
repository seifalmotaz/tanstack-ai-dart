// Upstream reference: packages/ai-client/tests/chat-fetcher.test.ts
//
// Canonical Dart surface: `ChatFetcher` from
// `lib/src/connections/stream_connections.dart` receives
// `ChatFetcherInput{messages,data,threadId,runId,parentRunId,resume}` plus
// `{signal, headers}` and returns either a `Stream<StreamChunk>` or an
// `http.StreamedResponse`.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:test/test.dart';

import 'support.dart';

http.StreamedResponse sseResponse(
  List<Map<String, dynamic>> chunks, {
  int status = 200,
  String? reasonPhrase,
}) {
  final body = chunks.map((chunk) => 'data: ${jsonEncode(chunk)}\n\n').join();
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    status,
    reasonPhrase: reasonPhrase,
  );
}

void main() {
  group('ChatClient — fetcher transport', () {
    test('runs an in-process AsyncIterable fetcher and streams text', () async {
      final seen = <conn.ChatFetcherInput>[];
      final client = ChatClient(
        fetcher: (input, {signal, headers}) {
          seen.add(input);
          return Stream<Map<String, dynamic>>.fromIterable(
            textChunks('Hello world'),
          );
        },
      );
      await client.sendText('Hi');
      expect(seen, hasLength(1));
      final assistant = client.getMessages().last;
      expect(assistant.role, 'assistant');
      expect(assistant.answer, 'Hello world');
    });

    test('parses an SSE Response returned by the fetcher (server-fn style)',
        () async {
      final client = ChatClient(
        fetcher: (input, {signal, headers}) async =>
            sseResponse(textChunks('Hi')),
      );
      await client.sendText('hi');
      expect(client.getMessages().last.answer, 'Hi');
      expect(client.getStatus(), isNot('error'));
    });

    test('passes the AbortSignal to the fetcher; stop() aborts it', () async {
      conn.CancellationSignal? seen;
      final started = Completer<void>();
      final client = ChatClient(
        fetcher: (input, {signal, headers}) {
          seen = signal;
          started.complete();
          return Completer<Object>().future;
        },
      );
      final send = client.sendText('hi');
      await started.future;
      expect(seen, isNotNull);
      expect(seen!.isCancelled, isFalse);

      await client.stop();
      await send;
      expect(seen!.isCancelled, isTrue);
    });

    test('surfaces a fetcher error as a ChatClient error', () async {
      Object? observed;
      final client = ChatClient(
        fetcher: (input, {signal, headers}) async =>
            throw StateError('fetcher exploded'),
        onError: (error, chunk) => observed = error,
      );
      await client.sendText('hi');
      expect(observed, isNotNull);
      expect(observed.toString(), contains('fetcher exploded'));
      expect(client.getStatus(), 'error');
    });

    test('surfaces a malformed-SSE Response as a ChatClient error', () async {
      final client = ChatClient(
        fetcher: (input, {signal, headers}) async => http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode('data: { not valid json\n\n'),
          ),
          200,
        ),
      );
      await client.sendText('hi');
      expect(client.getError(), isNotNull);
      expect(client.getError(), contains('FormatException'));
      expect(client.getStatus(), 'error');
    });

    test('passes UI messages and merged body to the fetcher', () async {
      conn.ChatFetcherInput? seen;
      final client = ChatClient(
        body: <String, dynamic>{'provider': 'openai'},
        fetcher: (input, {signal, headers}) {
          seen = input;
          return Stream<Map<String, dynamic>>.fromIterable(
            textChunks('ok'),
          );
        },
      );
      await client.sendText('hello there');
      expect(seen, isNotNull);
      expect(seen!.messages, hasLength(1));
      expect(seen!.messages.first['role'], 'user');
      expect((seen!.messages.first['parts'] as List).first, <String, dynamic>{
        'type': 'text',
        'content': 'hello there',
      });
      expect(seen!.data, containsPair('provider', 'openai'));
      expect(seen!.threadId, isNotEmpty);
      expect(seen!.runId, isNotEmpty);
    });

    test('throws when both connection and fetcher are passed', () {
      expect(
        () => ChatClient(
          connection: conn.ConnectionAdapter(
            connect: (messages, {data, signal, runContext}) async* {},
          ),
          fetcher: (input, {signal, headers}) => const Stream.empty(),
        ),
        throwsArgumentError,
      );
    });

    test('throws when neither connection nor fetcher is passed', () {
      expect(() => ChatClient(), throwsArgumentError);
    });

    test('surfaces a non-OK Response as a ChatClient error', () async {
      final client = ChatClient(
        fetcher: (input, {signal, headers}) async => http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode('Internal Server Error'),
          ),
          500,
          reasonPhrase: 'Internal Server Error',
        ),
      );
      await client.sendText('hi');
      expect(client.getError(), contains('500'));
      expect(client.getStatus(), 'error');
    });

    test('surfaces a non-stream result from the fetcher as a ChatClient error',
        () async {
      final client = ChatClient(
        fetcher: (input, {signal, headers}) async => Object(),
      );
      await client.sendText('hi');
      expect(client.getError(), contains('must return'));
      expect(client.getStatus(), 'error');
    });

    test('surfaces an AsyncIterable that throws after yielding chunks',
        () async {
      Stream<Map<String, dynamic>> failing() async* {
        yield <String, dynamic>{
          'type': 'TEXT_MESSAGE_CONTENT',
          'messageId': 'm1',
          'delta': 'x',
        };
        throw StateError('mid-stream boom');
      }

      final client = ChatClient(
        fetcher: (input, {signal, headers}) => failing(),
      );
      await client.sendText('hi');
      expect(client.getError(), contains('mid-stream boom'));
      expect(client.getStatus(), 'error');
    });

    test('completes cleanly when AsyncIterable ends without RUN_FINISHED',
        () async {
      Stream<Map<String, dynamic>> noTerminal() async* {
        for (final chunk in textChunks('Hello')) {
          if (chunk['type'] == 'RUN_FINISHED') continue;
          yield chunk;
        }
      }

      final client = ChatClient(
        fetcher: (input, {signal, headers}) => noTerminal(),
      );
      await client.sendText('hi');
      expect(client.getStatus(), isNot('error'));
      expect(client.getMessages().last.answer, 'Hello');
    });

    test('stops consuming chunks from an AsyncIterable that ignores its signal',
        () async {
      final observed = <Map<String, dynamic>>[];
      final client = ChatClient(
        fetcher: (input, {signal, headers}) =>
            Stream<Map<String, dynamic>>.periodic(
          const Duration(milliseconds: 5),
          (i) => <String, dynamic>{
            'type': 'TEXT_MESSAGE_CONTENT',
            'messageId': 'm1',
            'delta': '$i',
          },
        ),
        onChunk: observed.add,
      );
      final send = client.sendText('hi');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final beforeStop = observed.length;
      expect(beforeStop, greaterThan(0));

      await client.stop();
      await send;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(observed.length, beforeStop);
      expect(client.isStreaming, isFalse);
    });
  });
}
