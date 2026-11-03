// Intentionally verifies retained upstream compatibility symbols.
// ignore_for_file: deprecated_member_use_from_same_package

import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

void main() {
  test('root exports compose modern clients and shared tool/schema types',
      () async {
    final tool = ClientTool<int, String>(
        name: 'lookup', execute: (input, context) => '$input');
    final adapter = ConnectionAdapter.connect(
        connect: (messages, {data, signal, runContext}) async* {
      yield {'type': 'RUN_FINISHED', 'runId': runContext!.runId};
    });
    final chat = ChatClient.legacy(
        connection: adapter,
        tools: clientTools([tool]),
        initialResume:
            const ChatResumeState(threadId: 'thread', runId: 'past'));
    final generation =
        GenerationClient<String, String, String>.legacy(connection: adapter);
    expect(GENERATION_EVENTS['RESULT'], GenerationEvents.result);
    expect(EMPTY_BYOK_SNAPSHOT, same(emptyByokSnapshot));
    expect(chat.getSnapshot().messages, isEmpty);
    expect(generation.getSnapshot().isLoading, isFalse);
    expect(const ChatHydrateOptions(limit: 10).limit, 10);
    expect(const ChatHydrationPage().truncated, isFalse);
    await chat.dispose();
    generation.dispose();
  });
}
