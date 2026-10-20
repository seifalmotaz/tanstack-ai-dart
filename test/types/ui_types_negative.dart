// Negative analyzer fixture for the typed UI helpers.
//
// Every `expect-error` line must produce the named analyzer diagnostic. These
// are static rejections, not runtime casts or runtimeType checks.
// ignore_for_file: unused_local_variable
import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/ui.dart';

typedef WeatherInput = Map<String, dynamic>;

class WeatherOutput {
  final int temperature;

  const WeatherOutput(this.temperature);
}

class OtherOutput {
  final String label;

  const OtherOutput(this.label);
}

void main() {
  final weatherTool = ClientTool<WeatherInput, WeatherOutput>(
    name: 'getWeather',
    execute: (input, context) => WeatherOutput(21),
  );
  final call = AssistantPart.tool(
    id: 'call-1',
    name: 'getWeather',
    input: <String, dynamic>{'city': 'Paris'},
    output: const WeatherOutput(21),
  );
  final result = AssistantPart(
    type: 'tool-result',
    toolCallId: 'call-1',
    output: const WeatherOutput(21),
    outcome: 'success',
  );
  final typed = selectToolPart(call, weatherTool, result: result);

  // The typed input remains a WeatherInput, not String.
  // expect-error: invalid_assignment
  final String wrongInput = typed!.input;

  // The typed output remains WeatherOutput, not int.
  // expect-error: invalid_assignment
  final int wrongOutput = typed.output;

  final typedResult = selectToolResult<WeatherOutput>(result);
  // Tool-result output is not a String.
  // expect-error: invalid_assignment
  final String wrongResultOutput = typedResult!.output;

  final structuredPart = AssistantPart(
    type: 'structured-output',
    data: <String, dynamic>{'title': 'Pizza'},
  );
  final structured = selectStructuredPart<Map<String, Object?>>(structuredPart);
  // Structured data is a map, not a String.
  // expect-error: invalid_assignment
  final String wrongStructuredData = structured!.data;

  final interrupt = ChatInterrupt(
    id: 'interrupt-1',
    kind: 'generic',
    reason: 'choose',
    threadId: 'thread-1',
    interruptedRunId: 'run-1',
    generation: 1,
    definitionId: 'choosePlan',
    payload: <String, dynamic>{'title': 'Pizza'},
  );
  final interruptView =
      selectRegisteredInterrupt<Map<String, dynamic>, WeatherOutput>(
    interrupt,
    definitionId: 'choosePlan',
  );
  // Interrupt payload is a map, not a String.
  // expect-error: invalid_assignment
  final String wrongPayload = interruptView!.payload;

  // The registered response is WeatherOutput, not a raw String.
  // expect-error: argument_type_not_assignable
  interruptView.resolve('not a WeatherOutput');

  // A different response model is rejected as well.
  // expect-error: argument_type_not_assignable
  interruptView.resolve(const OtherOutput('wrong'));
}
