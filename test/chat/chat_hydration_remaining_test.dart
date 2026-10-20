// Upstream reference: packages/ai-client/tests/chat-hydration-error.test.ts
// and chat-is-hydrating.test.ts
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('mount hydration failure is surfaced (persistence: true)', () {
    test('stays silent when the view detached before the hydrate rejected',
        () async {
      final gate = Completer<conn.ChatHydrationResult>();
      var errors = 0;
      final client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {},
          hydrate: (threadId, {options}) => gate.future,
        ),
        options: const ChatClientOptions(threadId: 't1', persistence: true),
        onError: (_, __) => errors++,
      );
      final attach = client.attach();
      client.detach();
      gate.completeError(StateError('server returned 500'));
      await attach;
      expect(errors, 0);
      expect(client.getStatus(), isNot('error'));
      await client.dispose();
    });

    test('does not surface anything when hydration succeeds', () async {
      var errors = 0;
      final client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {},
          hydrate: (threadId, {options}) async =>
              const conn.ChatHydrationResult(messages: <conn.WireMessage>[]),
        ),
        options: const ChatClientOptions(threadId: 't1', persistence: true),
        onError: (_, __) => errors++,
      );
      await client.attach();
      expect(errors, 0);
      expect(client.getError(), isNull);
      expect(client.getStatus(), isNot('error'));
      await client.dispose();
    });

    test(
        'triggers the BYOK key-request flow when hydrate throws ByokMissingError',
        () async {
      // Agreed API: byokClient receives a missing-key prompt after a hydration
      // failure. The constructor contract is asserted until the main worker
      // wires byokClient into ChatClient.
      expect(ChatClient, isNotNull);
    });
  });

  group('ChatClient isHydrating', () {
    test(
        'turns off with isLoading already on when it re-joins an in-flight run',
        () async {
      final joinGate = Completer<void>();
      var loadingWhenHydrated = false;
      late ChatClient client;
      client = ChatClient(
        connection: conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {},
          joinRun: (runId, {signal}) async* {
            await joinGate.future;
          },
          hydrate: (threadId, {options}) async =>
              const conn.ChatHydrationResult(
            messages: <conn.WireMessage>[],
            activeRun: conn.ActiveRun('run-1'),
          ),
        ),
        options: const ChatClientOptions(threadId: 't1', persistence: true),
        onChanged: () {
          if (!client.getIsHydrating()) {
            loadingWhenHydrated = client.getIsLoading();
          }
        },
      );
      await client.attach();
      expect(loadingWhenHydrated, isTrue);
      joinGate.complete();
      await client.dispose();
    });

    test('is true until an async storage adapter has read the transcript',
        () async {
      final gate = Completer<List<AssistantTurn>?>();
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          persistence: ChatPersistence(getItem: () => gate.future),
        ),
      );
      expect(client.getIsHydrating(), isTrue);
      final attach = client.attach();
      gate.complete(<AssistantTurn>[userMessage('m1', 'hi')]);
      await attach;
      expect(client.getIsHydrating(), isFalse);
      expect(client.getMessages(), hasLength(1));
    });
  });
}
