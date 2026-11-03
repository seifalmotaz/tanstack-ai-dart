// ignore_for_file: unused_local_variable
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';

void dartApi() {
  final connection =
      fetchServerSentEvents('/chat', options: const FetchConnectionOptions());
  final dynamicConnection = fetchServerSentEventsProvider(
      url: () async => '/chat',
      options: () async => const FetchConnectionOptions());
  final client = ChatClient(
      connection: connection,
      persistence: const ChatPersistenceOptions.server(threadId: 'thread'));
  final Stream<ChatSnapshot> states = client.states;
  final ChatClientState state = client.snapshot.state;
  client.sendText('Hello');
  client.sendMessage(const ChatMessageInput.text('Hello', id: 'user'));
  client.sendMessage(ChatMessageInput.parts([AssistantPart.text('Hello')]));
  client.body = null;
  client.tools = [
    ClientTool<String, int>(
        name: 'length', execute: (text, context) => text.length)
  ];
  final generated = GenerationClient<String, int, int>.fetcher(
      fetcher: (text, options) => GenerationFetchResult.value(text.length));
  final video = VideoGenerationClient<VideoGenerateResult>.fetcher(
      fetcher: (_, options) => const GenerationFetchResult.value(
          VideoGenerateResult(jobId: 'job', url: 'url')));
  ChatFetcherResult fetcher(ChatFetcherInput input,
          {CancellationSignal? signal, Map<String, String>? headers}) =>
      ChatFetcherResult.stream(const Stream.empty());
  final custom = ChatClient(connection: fetcherToConnectionAdapter(fetcher));
}
