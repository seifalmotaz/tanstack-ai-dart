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
      send: (_, {data, signal, runContext}) async {});
  // expect-error: undefined_named_parameter
  ConnectionAdapter.connect(
      connect: (_, {data, signal, runContext}) => const Stream.empty(),
      subscribe: ({signal}) => const Stream.empty());
  // expect-error: undefined_named_parameter
  ConnectionAdapter.subscription(
      subscribe: ({signal}) => const Stream.empty(),
      send: (_, {data, signal, runContext}) async {},
      connect: (_, {data, signal, runContext}) => const Stream.empty());
  // expect-error: missing_required_argument
  ChatClient();
  final client =
      ChatClient(connection: stream((_, data, signal) => const Stream.empty()));
  // expect-error: argument_type_not_assignable
  client.sendMessage('hello');
  // expect-error: invalid_assignment
  client.body = 'bad';
  // expect-error: list_element_type_not_assignable
  client.tools = ['bad'];
  // expect-error: assignment_to_final_no_setter
  client.status = ChatClientStatus.error;
  // expect-error: assignment_to_final_no_setter
  client.error = 'bad';
  // expect-error: argument_type_not_assignable
  ChatClient(connection: client.connection!, persistence: true);
  // expect-error: undefined_named_parameter
  ChatClient(connection: client.connection!, options: ChatClientOptions());
  // expect-error: return_of_invalid_type_from_closure
  fetcherToConnectionAdapter((_, {signal, headers}) => 'bad');
  // expect-error: argument_type_not_assignable
  GenerationClient<String, int, int>.fetcher(
      fetcher: (_, options) => GenerationFetchResult.value('bad'));
  // expect-error: missing_required_argument
  GenerationClient<String, int, int>();
  // expect-error: argument_type_not_assignable
  VideoGenerationClient<VideoGenerateResult>.fetcher(
      fetcher: (_, options) => GenerationFetchResult.value(42));
  // expect-error: argument_type_not_assignable
  ClientTool<String, int>(name: 'tool', inputSchema: {'type': 'string'});
  // expect-error: missing_required_argument
  GenerationPersistenceOptions.persistent();
  // expect-error: assignment_to_final_no_setter
  client.connection = null;
}
