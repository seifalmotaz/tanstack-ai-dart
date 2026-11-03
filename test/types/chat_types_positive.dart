// Dart type fixture for the ported chat surface.
//
// Positive cases must analyze without errors. They mirror the compile-time
// contracts from the upstream `.test-d.ts` files: fetcher/connection/transport
// shapes, BYOK wiring, persistence + threadId pairing, tool callbacks, queue
// policies, interrupt definitions and snapshot/subscription helpers.
//
// Negative cases live in `chat_types_negative.dart`; each one is annotated with
// the analyzer diagnostic it must produce.
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:tanstack_ai_dart/byok.dart';
import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;

void positiveCases() {
  // Transport variants. Exactly one of connection/fetcher/transport is passed.
  final connection = conn.ConnectionAdapter.connect(
    connect: (messages, {data, signal, required runContext}) async* {
      yield <String, dynamic>{
        'type': 'RUN_FINISHED',
        'runId': runContext.runId,
        'threadId': runContext.threadId,
        'outcome': <String, dynamic>{'type': 'success'},
      };
    },
  );
  final byConnection = ChatClient.legacy(connection: connection);
  final byTransport = ChatClient.legacy(
      transport: SseChatTransport('https://x',
          headers: () => const <String, String>{}));

  // Canonical fetcher: input{...} in, Stream<Map> or http.StreamedResponse out.
  Stream<Map<String, dynamic>> chunkFetcherImpl(
    conn.ChatFetcherInput input, {
    conn.CancellationSignal? signal,
    Map<String, String>? headers,
  }) async* {
    yield <String, dynamic>{
      'type': 'RUN_STARTED',
      'threadId': input.threadId,
      'runId': input.runId,
    };
    yield <String, dynamic>{
      'type': 'RUN_FINISHED',
      'threadId': input.threadId,
      'runId': input.runId,
      'outcome': <String, dynamic>{'type': 'success'},
    };
  }

  Future<http.StreamedResponse> responseFetcherImpl(
    conn.ChatFetcherInput input, {
    conn.CancellationSignal? signal,
    Map<String, String>? headers,
  }) async =>
      http.StreamedResponse(const Stream<List<int>>.empty(), 200);

  conn.ChatFetcherResult chunkFetcher(conn.ChatFetcherInput input,
          {conn.CancellationSignal? signal, Map<String, String>? headers}) =>
      conn.ChatFetcherResult.stream(
          chunkFetcherImpl(input, signal: signal, headers: headers));
  Future<conn.ChatFetcherResult> responseFetcher(conn.ChatFetcherInput input,
          {conn.CancellationSignal? signal,
          Map<String, String>? headers}) async =>
      conn.ChatFetcherResult.response(
          await responseFetcherImpl(input, signal: signal, headers: headers));
  final byFetcher = ChatClient.legacy(fetcher: chunkFetcher);
  final byResponseFetcher = ChatClient.legacy(fetcher: responseFetcher);

  final input = conn.ChatFetcherInput(
    messages: const <conn.WireMessage>[
      <String, dynamic>{
        'id': 'u1',
        'role': 'user',
        'parts': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'content': 'hi'},
        ],
      },
    ],
    data: const <String, dynamic>{'model': 'gpt'},
    threadId: 'thread-1',
    runId: 'run-1',
    parentRunId: 'run-0',
    resume: const <Map<String, dynamic>>[
      <String, dynamic>{'interruptId': 'i1', 'status': 'resolved'},
    ],
  );
  assert(input.messages.first['role'] == 'user');

  // BYOK wiring and response hook.
  final byok = ByokClient(
    const DefineByokOptions(
      providers: <ByokProvider>[
        ByokProvider(id: 'openai', label: 'OpenAI'),
      ],
    ),
  );
  final byokWired = ChatClient.legacy(
    fetcher: chunkFetcher,
    byokClient: byok,
    byokProvider: () async => 'openai',
    onResponse: () async {},
  );

  // Every ChatClientOptions slot accepts its documented type.
  final options = ChatClientOptions(
    threadId: 'thread-1',
    queue: const ChatQueueConfig(
      whenBusy: QueueWhenBusy.queue,
      drain: QueueDrainMode.fifo,
      maxSize: 4,
      onOverflow: QueueOverflow.dropOldest,
    ),
    history: const ChatHistoryConfig(pageSize: 20),
    hydrate: (threadId, options) async =>
        const LegacyChatHydrationResult(messages: <AssistantTurn>[]),
    context: <String, dynamic>{'tenant': 'acme'},
    tools: <ChatClientTool>[
      ChatClientTool(
        name: 'lookup',
        description: 'Lookup a record',
        needsApproval: false,
        execute: (input, context) async => <String, dynamic>{'ok': true},
        validateOutput: (output) {},
      ),
    ],
    interrupts: <ChatInterruptDefinition>[
      ChatInterruptDefinition(id: 'plan', validate: (payload) {}),
    ],
    body: const <String, dynamic>{'model': 'gpt'},
    forwardedProps: const <String, dynamic>{'provider': 'openai'},
    initialResume: const ChatResumeState(threadId: 't', runId: 'r'),
    initialInterrupts: const ChatHydrationInterrupts(
      runId: 'r',
      pending: <Map<String, dynamic>>[],
    ),
    persistence: ChatPersistence(
      getItem: () async => const <AssistantTurn>[],
      setItem: (messages) async {},
      removeItem: () async {},
    ),
    onMessagesChange: (messages) {},
    onLoadingChange: (loading) {},
    onChunk: (chunk) {},
    onFinish: (chunk) {},
    onError: (error, chunk) {},
    onQueueChange: (queue) {},
    onSessionGeneratingChange: (generating) {},
    onRunIdChange: (runId) {},
    onInterruptStateChange: (state, source) {},
    onCustomEvent: (event, context) {},
  );
  final configured = ChatClient.legacy(
    transport:
        SseChatTransport('https://x', headers: () => const <String, String>{}),
    options: options,
  );

  final serverPersistence = ChatPersistenceOptions.server(
      history: const ChatHistoryConfig(pageSize: 50));
  final typedServerClient = ChatClient.legacy(
      threadId: 'support-42',
      connection: connection,
      persistenceOptions: serverPersistence);
  final booleanServerClient = ChatClient.legacy(
      options: ChatClientOptions(
          connection: connection, persistence: true, threadId: 'support-42'));
  assert(typedServerClient.threadId == booleanServerClient.threadId);
  final typedOptions = createChatClientOptions(ChatClientOptions(
      connection: connection, byok: byok, onResponse: () async {}));
  final fromOptions = ChatClient.legacy(options: typedOptions);
  fromOptions.getSnapshot();

  // Runtime helpers keep their parameter contracts.
  configured.updateLegacyOptions(
    context: null,
    body: const <String, dynamic>{'model': 'gpt'},
    forwardedProps: const <String, dynamic>{'provider': 'openai'},
    queue: const ChatQueueConfig(),
  );
  configured.subscribe(restart: true);
  configured.cancelQueued('queued-1');
  configured.addToolResult(toolCallId: 'tc', output: 1);
  configured.addLegacyToolApprovalResponse(id: 'a1', approved: true);
  configured.resumeInterruptsUnsafe(
    const <Map<String, dynamic>>[
      <String, dynamic>{'interruptId': 'i1', 'status': 'resolved'},
    ],
    threadId: 't',
    runId: 'r',
  );
  final unsubscribe = configured.subscribeSnapshot(() {});
  unsubscribe();

  // Message and part constructors accept the documented JSON shapes.
  final user = AssistantTurn(
    id: 'u1',
    role: 'user',
    parts: <AssistantPart>[
      AssistantPart.text('hi'),
      AssistantPart.tool(
        id: 'tc',
        name: 'lookup',
        approval: AssistantApproval(id: 'a1'),
      ),
    ],
  );
  final assistant = AssistantTurn.assistant();
  assert(user.role == 'user');
  assert(assistant.role == 'assistant');

  // Keep every binding live so the fixture is not optimized away by the
  // analyzer's unused-local diagnostics.
  assert(byConnection.threadId == null);
  assert(byTransport.getStatus().isNotEmpty);
  assert(byFetcher.getStatus().isNotEmpty);
  assert(byResponseFetcher.getStatus().isNotEmpty);
  assert(byokWired.getMessages().isEmpty);
}
