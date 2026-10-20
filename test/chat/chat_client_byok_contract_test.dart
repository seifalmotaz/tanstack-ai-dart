// Upstream reference: packages/ai-client/tests/byok-chat-client.test.ts
//
// BYOK is wired through the modern `ConnectionAdapter` API (not the legacy
// `ChatTransport`): provider resolution and header stamping happen in the
// connection path, so every case here records `runContext.headers`.
import 'dart:convert';

import 'package:tanstack_ai_dart/byok.dart';
import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:test/test.dart';

class RecordingConnection {
  final headers = <Map<String, String>>[];
  final data = <Map<String, dynamic>?>[];
  var connects = 0;
  Object? error;

  late final conn.ConnectionAdapter adapter = conn.ConnectionAdapter(
    connect: (messages, {data, signal, runContext}) async* {
      connects++;
      this.data.add(data);
      headers.add(runContext?.headers ?? const <String, String>{});
      if (error != null) throw error!;
      yield <String, dynamic>{
        'type': 'RUN_FINISHED',
        'runId': runContext?.runId ?? 'r',
        'threadId': runContext?.threadId ?? 't',
        'outcome': <String, dynamic>{'type': 'success'},
      };
    },
  );
}

ChatClient byokClient(
  ByokClient byok,
  RecordingConnection connection, {
  Future<String?> Function()? provider,
  Map<String, dynamic>? body,
  Map<String, dynamic>? forwardedProps,
  ChatPersistence? persistence,
  String? threadId,
}) =>
    ChatClient(
      connection: connection.adapter,
      byokClient: byok,
      byokProvider: provider,
      body: body,
      forwardedProps: forwardedProps,
      persistence: persistence,
      threadId: threadId,
    );

void main() {
  group('ChatClient byok', () {
    test('stamps x-byok headers and keeps the key out of the body', () async {
      const key = 'sk-live-secret';
      final byok = ByokClient();
      await byok.update('openai', key);
      final connection = RecordingConnection();
      final client = byokClient(
        byok,
        connection,
        body: <String, dynamic>{'provider': 'openai', 'model': 'gpt-5.5'},
      );

      await client.sendText('Hello');

      expect(connection.headers.single, <String, String>{'x-byok-openai': key});
      expect(connection.data.single,
          <String, dynamic>{'provider': 'openai', 'model': 'gpt-5.5'});
      expect(jsonEncode(connection.data.single), isNot(contains(key)));
      await client.stop();
    });

    test('stamps only the resolved provider when the ring has multiple keys',
        () async {
      const key = 'sk-live-secret';
      final byok = ByokClient();
      await byok.update('openai', key);
      await byok.update('anthropic', 'sk-anthropic-secret');
      final connection = RecordingConnection();
      final client = byokClient(
        byok,
        connection,
        body: <String, dynamic>{'provider': 'openai', 'model': 'gpt-5.5'},
      );

      await client.sendText('Hello');

      expect(connection.headers.single, <String, String>{'x-byok-openai': key});
      expect(connection.headers.single, isNot(contains('x-byok-anthropic')));
      await client.stop();
    });

    test('stamps BYOK headers for per-call body.provider', () async {
      // Fails until main resolves the provider from the merged per-call body,
      // not only from constructor `body`.
      final byok = ByokClient();
      await byok.update('openai', 'sk-live-secret');
      await byok.update('anthropic', 'sk-anthropic-secret');
      final connection = RecordingConnection();
      final client = byokClient(
        byok,
        connection,
        body: <String, dynamic>{'provider': 'openai', 'model': 'gpt-5.5'},
      );

      await client.sendMessage(
        'Hello',
        body: <String, dynamic>{'provider': 'anthropic'},
      );

      expect(connection.headers.single,
          <String, String>{'x-byok-anthropic': 'sk-anthropic-secret'});
      expect(connection.headers.single, isNot(contains('x-byok-openai')));
      expect(connection.data.single,
          <String, dynamic>{'provider': 'anthropic', 'model': 'gpt-5.5'});
      await client.stop();
    });

    test('stamps the only saved key when no provider slug is passed', () async {
      const key = 'sk-live-secret';
      final byok = ByokClient();
      await byok.update('openai', key);
      final connection = RecordingConnection();
      final client = byokClient(byok, connection);

      await client.sendText('Hello');

      expect(connection.headers.single, <String, String>{'x-byok-openai': key});
      await client.stop();
    });

    test('prompts for the only registered provider when no key is saved',
        () async {
      final byok = ByokClient(
        const DefineByokOptions(
          providers: <ByokProvider>[
            ByokProvider(id: 'openai', label: 'OpenAI'),
          ],
        ),
      );
      final connection = RecordingConnection();
      final client = byokClient(byok, connection);

      await client.sendText('Hello');

      expect(byok.getSnapshot().prompt?.provider, 'openai');
      expect(byok.getSnapshot().prompt?.reason, 'missing');
      expect(connection.connects, 0);
      expect(client.getStatus(), 'error');
    });

    test('sets an error and does not connect when no provider slug resolves',
        () async {
      final byok = ByokClient();
      await byok.update('openai', 'sk-live-secret');
      await byok.update('anthropic', 'sk-anthropic-secret');
      final connection = RecordingConnection();
      final client = byokClient(byok, connection);

      await client.sendText('Hello');

      expect(client.getStatus(), 'error');
      expect(client.getError(), contains('no provider slug'));
      expect(connection.connects, 0);
    });

    test(
        'rejects forwardedProps.provider that is not a slug without connecting',
        () async {
      final byok = ByokClient();
      await byok.update('openai', 'sk-live-secret');
      await byok.update('anthropic', 'sk-anthropic-secret');
      final connection = RecordingConnection();
      final client = byokClient(
        byok,
        connection,
        forwardedProps: <String, dynamic>{'provider': 'OpenAI'},
      );

      await client.sendText('Hello');

      expect(client.getStatus(), 'error');
      expect(connection.connects, 0);
    });

    test('stamps headers for slugs outside the old first-party list', () async {
      const key = 'sk-live-secret';
      final byok = ByokClient();
      await byok.update('bedrock', key);
      final connection = RecordingConnection();
      final client = byokClient(
        byok,
        connection,
        body: <String, dynamic>{'provider': 'bedrock', 'model': 'claude'},
      );

      await client.sendText('Hello');

      expect(
          connection.headers.single, <String, String>{'x-byok-bedrock': key});
      await client.stop();
    });

    test(
        'rejects ByokBlockedError and does not connect when the provider is empty',
        () async {
      final byok = ByokClient();
      final connection = RecordingConnection();
      final client = byokClient(
        byok,
        connection,
        body: <String, dynamic>{'provider': 'openai', 'model': 'gpt-5.5'},
      );

      await client.sendText('Hello');

      expect(client.getStatus(), 'error');
      expect(client.getError(), contains('Missing openai'));
      expect(byok.getSnapshot().prompt?.provider, 'openai');
      expect(byok.getSnapshot().prompt?.reason, 'missing');
      expect(connection.connects, 0);
    });

    test('rejects ByokMissingError from connect and sets the missing prompt',
        () async {
      final byok = ByokClient();
      await byok.update('openai', 'sk-live-secret');
      final connection = RecordingConnection()
        ..error = ByokMissingError('openai');
      final client = byokClient(
        byok,
        connection,
        body: <String, dynamic>{'provider': 'openai', 'model': 'gpt-5.5'},
      );

      await client.sendText('Hello');

      expect(client.getStatus(), 'error');
      expect(client.getError(), contains('ByokMissingError'));
      expect(byok.getSnapshot().prompt?.provider, 'openai');
      expect(byok.getSnapshot().prompt?.reason, 'missing');
    });

    test('does not persist the raw key or x-byok headers', () async {
      const key = 'sk-live-secret';
      final byok = ByokClient();
      await byok.update('openai', key);
      final stored = <AssistantTurn>[];
      final connection = RecordingConnection();
      final client = byokClient(
        byok,
        connection,
        body: <String, dynamic>{'provider': 'openai', 'model': 'gpt-5.5'},
        threadId: 'chat-1',
        persistence: ChatPersistence(
          getItem: () => const <AssistantTurn>[],
          setItem: (messages) => stored
            ..clear()
            ..addAll(messages),
        ),
      );

      await client.sendText('Hello');
      final serialized = stored.toString();

      expect(serialized, isNotEmpty);
      expect(serialized, isNot(contains(key)));
      expect(serialized, isNot(contains('x-byok-')));
      await client.stop();
    });
  });
}
