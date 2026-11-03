// Ported from
// packages/ai-client/tests/storage-adapters.test.ts
import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

class _MemoryWebStorage implements WebStorage {
  final Map<String, String> values = <String, String>{};

  @override
  String? getItem(String key) => values[key];

  @override
  void setItem(String key, String value) => values[key] = value;

  @override
  void removeItem(String key) => values.remove(key);
}

class _MemoryProvider implements WebStorageProvider {
  final _MemoryWebStorage local = _MemoryWebStorage();

  @override
  WebStorage? get localStorage => local;

  @override
  WebStorage? get sessionStorage => local;
}

void main() {
  group('localStoragePersistence createdAt revival', () {
    late _MemoryProvider provider;

    setUp(() {
      provider = _MemoryProvider();
    });

    test('revives a JSON-string createdAt back into a Date', () {
      final createdAt = DateTime.parse('2026-08-20T00:00:00.000Z');
      final store = localStoragePersistence(provider: provider);
      final record = ChatPersistedState(messages: [
        {
          'id': 'u1',
          'role': 'user',
          'parts': [
            {'type': 'text', 'content': 'hi'}
          ],
          'createdAt': createdAt,
        },
      ]);

      store.setItem('chat-1', record);
      final raw = provider.local.getItem('tanstack-ai:chat-1');
      expect(raw, contains('"createdAt":"2026-08-20T00:00:00.000Z"'));

      final state = store.getItem('chat-1') as ChatPersistedState;
      expect(state.messages[0]['createdAt'], createdAt);
      expect(state.messages[0]['createdAt'], isA<DateTime>());
    });

    test(
        'round-trips role activity as a UIMessage with the same id and content',
        () {
      final record = ChatPersistedState(messages: [
        {
          'id': 'u1',
          'role': 'user',
          'parts': [
            {'type': 'text', 'content': 'hi'}
          ],
        },
        {
          'id': 'act-1',
          'role': 'activity',
          'parts': [
            {
              'type': 'activity',
              'activityType': 'SEARCH',
              'content': {'query': 'tanstack'},
            },
          ],
        },
        {
          'id': 'a1',
          'role': 'assistant',
          'parts': [
            {'type': 'text', 'content': 'ok'}
          ],
        },
      ]);

      localStoragePersistence(provider: provider)
          .setItem('chat-activity', record);
      final raw = provider.local.getItem('tanstack-ai:chat-activity');
      expect(raw, contains('"role":"activity"'));
      expect(raw, contains('"activityType":"SEARCH"'));

      final read = localStoragePersistence(provider: provider)
          .getItem('chat-activity') as ChatPersistedState;
      expect(read.messages.map((message) => message['role']), [
        'user',
        'activity',
        'assistant',
      ]);
      final activity = read.messages[1];
      expect(activity['id'], 'act-1');
      expect((activity['parts'] as List).first, {
        'type': 'activity',
        'activityType': 'SEARCH',
        'content': {'query': 'tanstack'},
      });
    });

    test('revives tool-result createdAt values inside message parts', () {
      final record = ChatPersistedState(messages: [
        {
          'id': 'a1',
          'role': 'assistant',
          'parts': [
            {
              'type': 'tool-result',
              'toolCallId': 'c1',
              'content': 'ok',
              'state': 'complete',
              'createdAt': DateTime.parse('2026-08-20T00:00:00.000Z'),
            },
          ],
        },
      ]);
      localStoragePersistence(provider: provider).setItem('chat-2', record);
      final read = localStoragePersistence(provider: provider).getItem('chat-2')
          as ChatPersistedState;
      final part = (read.messages[0]['parts'] as List).first as Map;
      expect(part['type'], 'tool-result');
      expect(part['createdAt'], DateTime.parse('2026-08-20T00:00:00.000Z'));
    });

    test('removes invalid createdAt values from messages and tool results', () {
      provider.local.setItem(
        'tanstack-ai:chat-invalid',
        '{"messages":[{"id":"a1","role":"assistant","createdAt":"not-a-date",'
            '"parts":[{"type":"tool-result","toolCallId":"c1","content":"ok",'
            '"state":"complete","createdAt":"also-invalid"}]}]}',
      );
      final read = localStoragePersistence(provider: provider)
          .getItem('chat-invalid') as ChatPersistedState;
      expect(read.messages[0].containsKey('createdAt'), isFalse);
      final part = (read.messages[0]['parts'] as List).first as Map;
      expect(part.containsKey('createdAt'), isFalse);
    });

    test('preserves createdAt fields inside stored metadata', () {
      final metadata = {
        'createdAt': 'message-metadata',
        'tanstack': {'createdAt': '2026-08-20T00:00:00.000Z'},
        'nested': {'createdAt': 'nested-metadata'},
      };
      final partMetadata = {'createdAt': 'part-metadata'};
      provider.local.setItem(
        'tanstack-ai:chat-metadata',
        '{"messages":[{"id":"a1","role":"assistant","parts":[{"type":"text",'
            '"content":"ok","metadata":{"createdAt":"part-metadata"}}],'
            '"metadata":{"createdAt":"message-metadata","tanstack":'
            '{"createdAt":"2026-08-20T00:00:00.000Z"},"nested":'
            '{"createdAt":"nested-metadata"}}}]}',
      );

      final read = localStoragePersistence(provider: provider)
          .getItem('chat-metadata') as ChatPersistedState;
      expect(read.messages[0]['metadata'], metadata);
      final part = (read.messages[0]['parts'] as List).first as Map;
      expect(part['metadata'], partMetadata);
    });

    test('throws StorageUnavailableError when the injected store is absent',
        () {
      final store = localStoragePersistence();
      expect(
        () => store.setItem(
          'x',
          ChatPersistedState(messages: const <Map<String, dynamic>>[]),
        ),
        throwsA(isA<StorageUnavailableError>()),
      );
    });
  });
}
