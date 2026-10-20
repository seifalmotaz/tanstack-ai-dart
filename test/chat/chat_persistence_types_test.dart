// Upstream reference: packages/ai-client/tests/chat-persistence-types.test.ts
//
// Upstream's first six cases are pure TypeScript type assertions. The compile
// fixtures for those live in `test/types/chat_types_positive.dart` and
// `test/types/chat_types_negative.dart`; this file keeps only the cases that
// have a runtime contract in the Dart client.
import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';
import 'package:tanstack_ai_dart/platform.dart' show ChatPersistedState;
import 'package:tanstack_ai_dart/connections.dart' as conn;

import 'support.dart';

void main() {
  group('ChatClient persistence requires a threadId', () {
    test('rejects persistence without a threadId', () {
      expect(
        () => ChatClient(
          transport: FakeChatTransport(),
          persistence: ChatPersistence(getItem: () => null),
        ),
        throwsArgumentError,
      );
    });

    test('rejects a storage adapter option without a threadId', () {
      expect(
        () => ChatClient(
          transport: FakeChatTransport(),
          options: ChatClientOptions(
            persistence: ChatPersistence(getItem: () => null),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('accepts persistence when a threadId is supplied', () {
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          persistence: ChatPersistence(getItem: () => null),
        ),
      );
      expect(client.threadId, 't1');
    });

    test('leaves threadId optional for ephemeral chats', () {
      final client = ChatClient(transport: FakeChatTransport());
      expect(client.threadId, isNull);
    });
  });

  group('ChatClient history paging', () {
    test('rejects history on a storage adapter', () {
      expect(
          () => ChatClient(
                connection: conn.ConnectionAdapter(
                    connect: (_, {data, signal, runContext}) =>
                        const Stream.empty()),
                threadId: 't1',
                persistence: _Store(),
                history: const ChatHistoryConfig(pageSize: 20),
              ),
          throwsArgumentError);
    });
    test('accepts history.pageSize with persistence and a threadId', () {
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: ChatClientOptions(
          threadId: 't1',
          history: const ChatHistoryConfig(pageSize: 20),
          persistence: ChatPersistence(getItem: () => null),
        ),
      );
      expect(client.threadId, 't1');
    });
  });
}

class _Store implements ChatClientPersistence {
  @override
  Object? getItem(String id) => null;
  @override
  void setItem(String id, ChatPersistedState state) {}
  @override
  void removeItem(String id) {}
}
