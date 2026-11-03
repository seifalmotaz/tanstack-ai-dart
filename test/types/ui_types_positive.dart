// Positive analyzer fixture for the typed UI helpers.
//
// Each assertion is a real static type check against the generic helper API;
// there are no runtimeType comparisons or dynamic aliases here.
import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/ui.dart';

typedef WeatherInput = Map<String, dynamic>;

class WeatherOutput {
  final int temperature;

  const WeatherOutput(this.temperature);
}

void main() {
  final weatherTool = ClientTool<WeatherInput, WeatherOutput>(
    name: 'getWeather',
    description: 'Weather lookup',
    execute: (input, context) => WeatherOutput(21),
  );

  final List<ClientTool<WeatherInput, WeatherOutput>> tools =
      clientTools([weatherTool]);
  final call = AssistantPart.tool(
    id: 'call-1',
    name: 'getWeather',
    input: <String, dynamic>{'city': 'Paris'},
    output: const WeatherOutput(21),
    state: 'complete',
  );
  final result = AssistantPart(
    type: 'tool-result',
    toolCallId: 'call-1',
    output: const WeatherOutput(21),
    outcome: 'success',
    state: 'complete',
  );

  final ChatTypedToolPart<WeatherInput, WeatherOutput>? typed =
      selectToolPart(call, weatherTool, result: result);
  final WeatherInput? input = typed?.input;
  final WeatherOutput? output = typed?.output;
  final bool hasInput = typed?.hasInput ?? false;
  final bool hasOutput = typed?.hasOutput ?? false;
  final ChatTypedToolPart<WeatherInput, WeatherOutput>? selected = selectFromUI(
    ChatUISelectedToolPart(part: call, result: result),
    weatherTool,
  );

  final ChatTypedToolResult<WeatherOutput>? typedResult =
      selectToolResult<WeatherOutput>(result);
  final WeatherOutput? resultOutput = typedResult?.output;
  final String? outcome = typedResult?.outcome;
  final bool denied = typedResult?.denied ?? false;

  final structuredPart = AssistantPart(
    type: 'structured-output',
    structuredStatus: 'complete',
    raw: '{"title":"Pizza"}',
    data: <String, dynamic>{'title': 'Pizza'},
    partial: <String, dynamic>{'title': 'Pizza'},
  );
  final ChatTypedStructuredPart<Map<String, Object?>>? structured =
      selectStructuredPart<Map<String, Object?>>(structuredPart);
  final Map<String, Object?>? data = structured?.data;
  final Map<String, Object?>? partial = structured?.partial;
  final String raw = structured?.raw ?? '';

  final text = selectTextPart(AssistantPart.text('hello'));
  final String textContent = text?.content ?? '';
  final activity = selectActivityPart(
    AssistantPart(
      type: 'activity',
      activityType: 'SEARCH',
      activityContent: <String, dynamic>{'query': 'pizza'},
    ),
  );
  final String activityType = activity?.activityType ?? '';
  final Object? activityContent = activity?.content;

  final interrupt = ChatInterrupt(
    id: 'interrupt-1',
    kind: 'generic',
    reason: 'choose',
    threadId: 'thread-1',
    interruptedRunId: 'run-1',
    generation: 1,
    definitionId: 'choosePlan',
    payload: <String, dynamic>{'title': 'Pizza'},
    definition: const ChatInterruptDefinition(id: 'choosePlan'),
  );
  final ChatTypedInterrupt<Map<String, dynamic>, WeatherOutput>? interruptView =
      selectRegisteredInterrupt<Map<String, dynamic>, WeatherOutput>(
    interrupt,
    definitionId: 'choosePlan',
  );
  final Map<String, dynamic>? payload = interruptView?.payload;
  final bool canResolve = interruptView?.canResolve ?? false;
  interruptView?.resolve(const WeatherOutput(1));

  // Keep every typed binding live.
  print([
    tools,
    input,
    output,
    hasInput,
    hasOutput,
    selected?.name,
    resultOutput,
    outcome,
    denied,
    data,
    partial,
    raw,
    textContent,
    activityType,
    activityContent,
    payload,
    canResolve,
  ]);
}
