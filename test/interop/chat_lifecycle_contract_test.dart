import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:tanstack_ai_dart/byok.dart' as byok;
import 'package:test/test.dart';

void main() {
  test('connect drains events after intermediate and terminal run markers',
      () async {
    final client = ChatClient(connection: conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
      yield {
        'type': 'RUN_STARTED',
        'runId': runContext!.runId,
        'threadId': runContext.threadId
      };
      yield {
        'type': 'RUN_FINISHED',
        'runId': runContext.runId,
        'finishReason': 'tool_calls'
      };
      yield {
        'type': 'TEXT_MESSAGE_START',
        'messageId': 'late',
        'role': 'assistant'
      };
      yield {
        'type': 'TEXT_MESSAGE_CONTENT',
        'messageId': 'late',
        'delta': 'Drained'
      };
      yield {'type': 'RUN_FINISHED', 'runId': runContext.runId};
      yield {
        'type': 'TEXT_MESSAGE_CONTENT',
        'messageId': 'late',
        'delta': ' fully'
      };
      yield {'type': 'TEXT_MESSAGE_END', 'messageId': 'late'};
    }));
    addTearDown(client.dispose);
    await client.sendMessage('hello');
    expect(client.getMessages().last.answer, 'Drained fully');
    expect(client.isLoading, isFalse);
  });

  test('stop during awaited onResponse prevents the request', () async {
    final gate = Completer<void>();
    var requests = 0;
    final client = ChatClient(
        onResponse: () => gate.future,
        connection: conn.ConnectionAdapter(
            connect: (messages, {data, signal, runContext}) async* {
          requests++;
        }));
    addTearDown(client.dispose);
    final pending = client.sendMessage('hello');
    await Future<void>.delayed(Duration.zero);
    await client.stop();
    gate.complete();
    await pending.timeout(const Duration(seconds: 1));
    expect(requests, 0);
    expect(client.isLoading, isFalse);
  });

  test('BYOK prepares only the selected provider and stays out of wire data',
      () async {
    final keyring = byok.defineByok();
    await keyring.update('openai', 'fake-openai-marker');
    await keyring.update('anthropic', 'fake-anthropic-marker');
    conn.RunAgentInputContext? captured;
    final client = ChatClient(
        byokClient: keyring,
        byokProvider: () async => 'openai',
        connection: conn.ConnectionAdapter(
            connect: (messages, {data, signal, runContext}) async* {
          captured = runContext;
          expect('$messages$data', isNot(contains('fake-openai-marker')));
          yield {'type': 'RUN_FINISHED', 'runId': runContext!.runId};
        }));
    addTearDown(client.dispose);
    await client.sendMessage('hello');
    expect(captured!.headers!.values.join(), contains('fake-openai-marker'));
    expect(captured!.headers!.values.join(),
        isNot(contains('fake-anthropic-marker')));
  });
}
