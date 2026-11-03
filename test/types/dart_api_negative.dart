// ignore_for_file: unused_local_variable
import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';

void invalidDartApi() {
  // expect-error: argument_type_not_assignable
  fetchServerSentEvents(42);
  // expect-error: argument_type_not_assignable
  fetchServerSentEvents('/chat', options: 'bad');
  // expect-error: return_of_invalid_type_from_closure
  fetchServerSentEventsProvider(url: () => 42);
  // expect-error: missing_required_argument
  ConnectionAdapter.subscription(subscribe: ({signal}) => const Stream.empty());
  // expect-error: missing_required_argument
  ConnectionAdapter.subscription(
      send: (_, {data, signal, required runContext}) async {});
  // expect-error: undefined_named_parameter
  ConnectionAdapter.connect(
      connect: (_, {data, signal, required runContext}) => const Stream.empty(),
      subscribe: ({signal}) => const Stream.empty());
  // expect-error: undefined_named_parameter
  ConnectionAdapter.subscription(
      subscribe: ({signal}) => const Stream.empty(),
      send: (_, {data, signal, required runContext}) async {},
      connect: (_, {data, signal, required runContext}) =>
          const Stream.empty());
  // expect-error: missing_required_argument
  ChatClient();
  // expect-error: missing_required_argument
  ChatClient(connection: stream((_) => const Stream.empty()));
  final client = ChatClient(
      threadId: 'thread', connection: stream((_) => const Stream.empty()));
  // expect-error: argument_type_not_assignable
  client.sendMessage('hello');
  // expect-error: invalid_assignment
  client.legacyBody = 'bad';
  // expect-error: undefined_named_parameter
  ChatClient(threadId: 'thread', connection: client.connection!, body: {});
  // expect-error: list_element_type_not_assignable
  client.tools = ['bad'];
  // expect-error: assignment_to_final_no_setter
  client.status = ChatClientStatus.error;
  // expect-error: assignment_to_final_no_setter
  client.error = 'bad';
  // expect-error: argument_type_not_assignable
  ChatClient(
      threadId: 'thread', connection: client.connection!, persistence: true);
  // expect-error: undefined_named_parameter
  ChatClient(
      threadId: 'thread',
      connection: client.connection!,
      options: ChatClientOptions());
  // expect-error: return_of_invalid_type_from_closure
  fetcherToConnectionAdapter((_, {signal, headers}) => 'bad');
  // expect-error: argument_type_not_assignable
  GenerationClient<String, int, int>.fetcher(
      threadId: 'thread',
      fetcher: (_, options) => GenerationFetchResult.value('bad'));
  // expect-error: missing_required_argument
  GenerationClient<String, int, int>();
  // expect-error: missing_required_argument
  GenerationClient<String, int, int>.fetcher(
      fetcher: (_, options) => const GenerationFetchResult.value(1));
  // expect-error: missing_required_argument
  VideoGenerationClient<VideoGenerateResult>.fetcher(
      fetcher: (_, options) => const GenerationFetchResult.value(
          VideoGenerateResult(jobId: 'job', url: 'url')));
  // expect-error: argument_type_not_assignable
  VideoGenerationClient<VideoGenerateResult>.fetcher(
      threadId: 'thread',
      fetcher: (_, options) => GenerationFetchResult.value(42));
  // expect-error: argument_type_not_assignable
  ClientTool<String, int>(name: 'tool', inputSchema: {'type': 'string'});
  // expect-error: assignment_to_final_no_setter
  client.connection = null;
}
