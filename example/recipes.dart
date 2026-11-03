import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';

// #docregion refresh
ChatClient authenticatedChat(
  String endpoint,
  Future<String> Function() readAccessToken,
) =>
    ChatClient(
      connection: fetchServerSentEventsProvider(
        url: () => endpoint,
        options: () async => FetchConnectionOptions(
          headers: {'Authorization': 'Bearer ${await readAccessToken()}'},
        ),
      ),
    );
// #enddocregion refresh

// #docregion fetcher
ChatClient customHttpChat(
  Future<http.StreamedResponse> Function(
    ChatFetcherInput input,
    CancellationSignal? signal,
    Map<String, String>? headers,
  ) request,
) =>
    ChatClient(
      connection: fetcherToConnectionAdapter(
        (input, {signal, headers}) async => ChatFetcherResult.response(
          await request(input, signal, headers),
        ),
      ),
    );
// #enddocregion fetcher

// #docregion queue
ChatClient queuedChat(ConnectionAdapter connection) => ChatClient(
      connection: connection,
      queue: const ChatQueueConfig(
        whenBusy: QueueWhenBusy.queue,
        maxSize: 10,
        onOverflow: QueueOverflow.reject,
      ),
    );
// #enddocregion queue

// #docregion message
Future<void> sendParts(ChatClient client) => client.sendMessage(
      ChatMessageInput.parts(
        [AssistantPart.text('Show properties in Cairo')],
        id: 'customer-message-1',
        metadata: {'language': 'en'},
      ),
    );
// #enddocregion message

// #docregion server-persistence
ChatClient serverHistory(ConnectionAdapter connection, String threadId) =>
    ChatClient(
      connection: connection,
      persistence: ChatPersistenceOptions.server(
        threadId: threadId,
        history: const ChatHistoryConfig(pageSize: 20),
      ),
    );
// #enddocregion server-persistence

// #docregion stored-persistence
ChatClient storedHistory(
  ConnectionAdapter connection,
  ChatClientPersistence storage,
  String threadId,
) =>
    ChatClient(
      connection: connection,
      persistence: ChatPersistenceOptions.stored(
        threadId: threadId,
        adapter: storage,
      ),
    );
// #enddocregion stored-persistence

// #docregion tool
ClientTool<String, int> lengthTool() => ClientTool<String, int>(
      name: 'length',
      description: 'Count characters in text',
      inputSchema: StandardSchema(
        (value) => value is String
            ? SchemaValidationResult.success(value)
            : const SchemaValidationResult.failure(
                [SchemaIssue('Expected text')],
              ),
        schema: {'type': 'string'},
      ),
      execute: (text, context) => text.length,
    );
// #enddocregion tool

// #docregion approval
Future<void> answerApproval(
  ChatClient client,
  String approvalId,
  bool approved,
) =>
    client.addToolApprovalResponse(id: approvalId, approved: approved);
// #enddocregion approval

// #docregion rendering
String summarizePart(ChatPart part) => switch (part) {
      ChatTextPart(:final content) => content,
      ChatThinkingPart(:final content) => content,
      ChatToolCallPart(:final name) => 'Tool: $name',
      ChatToolResultPart(:final output) => 'Result: $output',
      ChatActivityPart(:final activityType) => 'Activity: $activityType',
      ChatStructuredPart(:final data) => 'Data: $data',
      ChatSubagentPart(:final id) => 'Agent: $id',
      ChatMediaPart(:final mediaType) => 'Media: $mediaType',
      ChatUnknownPart(:final type) => 'Unsupported part: $type',
    };
// #enddocregion rendering

// #docregion generation
Future<String?> generateText(
  Future<String> Function(String prompt, CancellationSignal signal) request,
  String prompt,
) async {
  final generator = GenerationClient<String, String, String>.fetcher(
    fetcher: (input, options) async => GenerationFetchResult.value(
      await request(input, options.signal),
    ),
  );
  try {
    await generator.generate(prompt);
    if (generator.error != null) throw generator.error!;
    return generator.result;
  } finally {
    generator.dispose();
  }
}
// #enddocregion generation

// #docregion video
VideoGenerationClient<VideoGenerateResult> videoClient(
  Future<VideoGenerateResult> Function(
    VideoGenerateInput input,
    GenerationFetcherOptions options,
  ) request,
) =>
    VideoGenerationClient<VideoGenerateResult>.fetcher(
      fetcher: (input, options) async => GenerationFetchResult.value(
        await request(input, options),
      ),
    );
// #enddocregion video

// #docregion copier
Map<String, List<int>> copyScores(Map<String, List<int>> value) =>
    Map<String, List<int>>.unmodifiable({
      for (final entry in value.entries)
        entry.key: List<int>.unmodifiable(entry.value),
    });
// #enddocregion copier
