// Upstream references: chat-client-noop-devtools.test.ts, replay-metadata.test.ts,
// and dispose-tail-leak.test.ts.
import 'dart:async';
import 'dart:convert';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:tanstack_ai_dart/src/devtools/devtools.dart';
import 'package:tanstack_ai_dart/src/devtools/devtools_factories.dart';
import 'package:tanstack_ai_dart/src/devtools/devtools_noop.dart';
import 'package:tanstack_ai_dart/src/devtools/devtools_types.dart';
import 'package:test/test.dart';

import 'support.dart';

ChatDevtoolsBridgeOptions noopOptions() => ChatDevtoolsBridgeOptions(
      hookId: 'hook',
      clientId: 'client',
      metadata: const AIDevtoolsClientMetadata(name: 'test', hookName: 'chat'),
      getMessages: () => <Map<String, dynamic>>[],
      setMessages: (_) {},
      addToolResult: (_, __, [___]) {},
      generateId: (prefix) => '$prefix-1',
    );

void main() {
  group('createChatDevtoolsBridge by NODE_ENV', () {
    test('emits no devtools events in production', () {
      final bridge = createChatDevtoolsBridge(noopOptions(), production: true);
      expect(bridge, isA<NoOpChatDevtoolsBridge>());
    });

    test('emits devtools events in development', () {
      final bridge = createChatDevtoolsBridge(noopOptions(), production: false);
      expect(bridge, isA<ChatDevtoolsBridge>());
    });

    test('does not throw when there is no process global', () {
      expect(() => createChatDevtoolsBridge(noopOptions()), returnsNormally);
    });
  });

  group('ChatClient with default no-op devtools bridge', () {
    test('sends the first message and appends it', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('hello');
      expect(client.getMessages().first.answer, 'hello');
      await client.stop();
    });

    test('updates tools without throwing', () {
      final client = ChatClient(transport: FakeChatTransport());
      expect(() => client.updateOptions(body: <String, dynamic>{'x': 1}),
          returnsNormally);
    });
  });

  group('saved replay metadata', () {
    test(
        'keeps source, failed-turn and response metadata through JSON storage and hydration',
        () {
      final row = AssistantTurn(
        id: 'a1',
        role: 'assistant',
        parts: <AssistantPart>[AssistantPart.text('answer')],
        metadata: <String, dynamic>{
          'tanstack': <String, dynamic>{
            'source': <String, dynamic>{
              'provider': 'openai',
              'api': 'responses',
              'model': 'test',
            },
            'finishReason': 'stop',
            'stopReason': 'error',
            'responseId': 'resp-1',
          },
        },
      ).toRow();
      final decoded = jsonDecode(jsonEncode(<String, dynamic>{
        'messages': <dynamic>[row],
      }));
      final restored = assistantTurnsFromThread(decoded);
      expect(restored.single.metadata!['tanstack'], <String, dynamic>{
        'source': <String, dynamic>{
          'provider': 'openai',
          'api': 'responses',
          'model': 'test',
        },
        'finishReason': 'stop',
        'stopReason': 'error',
        'responseId': 'resp-1',
      });
    });

    test('does not invent a server abort when the client stops', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x');
      await client.stop();
      expect(
        client.getMessages().last.metadata?['tanstack']?['stopReason'],
        isNull,
      );
    });
  });

  group('dispose stops a late hydration from opening a tail', () {
    test('does not join a run when hydration resolves after dispose', () async {
      final gate = Completer<conn.ChatHydrationResult>();
      var joins = 0;
      final client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {},
          joinRun: (runId, {signal}) async* {
            joins++;
          },
          hydrate: (threadId, {options}) => gate.future,
        ),
        options: const ChatClientOptions(threadId: 't1', persistence: true),
      );
      final attach = client.attach();
      await client.dispose();
      gate.complete(
        const conn.ChatHydrationResult(
          messages: <conn.WireMessage>[],
          activeRun: conn.ActiveRun('run-1'),
        ),
      );
      await attach;
      expect(joins, 0);
    });

    test('aborts an OPEN tail when the client is disposed', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x');
      await client.dispose();
      expect(transport.controllers.single.hasListener, isFalse);
    });

    test('detach drops the connection, and attach picks the run back up',
        () async {
      var joins = 0;
      final client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {},
          joinRun: (runId, {signal}) async* {
            joins++;
          },
          hydrate: (threadId, {options}) async =>
              const conn.ChatHydrationResult(
            messages: <conn.WireMessage>[],
            activeRun: conn.ActiveRun('run-1'),
          ),
        ),
        options: const ChatClientOptions(threadId: 't1', persistence: true),
      );
      await client.attach();
      client.detach();
      await client.attach();
      await pump(4);
      expect(joins, greaterThanOrEqualTo(1));
      await client.dispose();
    });

    test('attach is idempotent, so a wrapper mount after construction is free',
        () async {
      var hydrates = 0;
      final client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {},
          hydrate: (threadId, {options}) async {
            hydrates++;
            return const conn.ChatHydrationResult(
                messages: <conn.WireMessage>[]);
          },
        ),
        options: const ChatClientOptions(threadId: 't1', persistence: true),
      );
      await Future.wait(<Future<void>>[client.attach(), client.attach()]);
      expect(hydrates, 1);
      await client.dispose();
    });

    test('detach must not wipe a PERSISTED resume pointer', () async {
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: const ChatClientOptions(
          initialResume: ChatResumeState(threadId: 't', runId: 'r'),
        ),
      );
      client.detach();
      expect(client.getResumeState()?.runId, 'r');
    });

    test('an EPHEMERAL chat makes no request on attach or re-attach', () async {
      var requests = 0;
      final client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            requests++;
          },
        ),
      );
      await client.attach();
      await client.attach();
      expect(requests, 0);
    });

    test('a hydration that resolves after DETACH must not open a tail',
        () async {
      final gate = Completer<conn.ChatHydrationResult>();
      var joins = 0;
      final client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {},
          joinRun: (runId, {signal}) async* {
            joins++;
          },
          hydrate: (threadId, {options}) => gate.future,
        ),
        options: const ChatClientOptions(threadId: 't1', persistence: true),
      );
      final attach = client.attach();
      client.detach();
      gate.complete(
        const conn.ChatHydrationResult(
          messages: <conn.WireMessage>[],
          activeRun: conn.ActiveRun('run-1'),
        ),
      );
      await attach;
      await pump(4);
      expect(joins, 0);
      await client.dispose();
    });

    test('a re-attach while hydration is in flight reuses that GET', () async {
      final gate = Completer<conn.ChatHydrationResult>();
      var hydrates = 0;
      final client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {},
          hydrate: (threadId, {options}) {
            hydrates++;
            return gate.future;
          },
        ),
        options: const ChatClientOptions(threadId: 't1', persistence: true),
      );
      final first = client.attach();
      client.detach();
      final second = client.attach();
      expect(hydrates, 1);
      gate.complete(
          const conn.ChatHydrationResult(messages: <conn.WireMessage>[]));
      await Future.wait(<Future<void>>[first, second]);
      await client.dispose();
    });

    test('still joins the run when hydration resolves before dispose',
        () async {
      var joins = 0;
      final client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {},
          joinRun: (runId, {signal}) async* {
            joins++;
          },
          hydrate: (threadId, {options}) async =>
              const conn.ChatHydrationResult(
            messages: <conn.WireMessage>[],
            activeRun: conn.ActiveRun('run-1'),
          ),
        ),
        options: const ChatClientOptions(threadId: 't1', persistence: true),
      );
      await client.attach();
      await pump(4);
      expect(joins, 1);
      await client.dispose();
    });
  });
}
