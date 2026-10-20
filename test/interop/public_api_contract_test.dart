import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

void main() {
  test('root exports compose modern clients and shared tool/schema types',
      () async {
    final tool = ClientTool<int, String>(
        name: 'lookup', execute: (input, context) => '$input');
    final adapter = ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
      yield {'type': 'RUN_FINISHED', 'runId': runContext!.runId};
    });
    final chat = ChatClient(
        connection: adapter,
        tools: clientTools([tool]),
        initialResume:
            const ChatResumeState(threadId: 'thread', runId: 'past'));
    final generation =
        GenerationClient<String, String, String>(connection: adapter);
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
