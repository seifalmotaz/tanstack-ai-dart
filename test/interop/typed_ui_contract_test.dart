import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/ui.dart';
import 'package:test/test.dart';

typedef WeatherInput = Map<String, dynamic>;

class WeatherOutput {
  final int temperature;

  const WeatherOutput(this.temperature);

  @override
  bool operator ==(Object other) =>
      other is WeatherOutput && other.temperature == temperature;

  @override
  int get hashCode => temperature.hashCode;

  @override
  String toString() => 'WeatherOutput($temperature)';
}

ClientTool<WeatherInput, WeatherOutput> _weatherTool() =>
    ClientTool<WeatherInput, WeatherOutput>(
      name: 'getWeather',
      description: 'Weather lookup',
      execute: (input, context) =>
          WeatherOutput((input['temperature'] as int?) ?? 21),
    );

void main() {
  group('typed UI tool parts', () {
    test('binds typed input/output to the matching tool name', () {
      final tool = _weatherTool();
      final call = AssistantPart.tool(
        id: 'call-1',
        name: 'getWeather',
        input: <String, dynamic>{'city': 'Paris'},
        output: const WeatherOutput(21),
        state: 'complete',
      );

      final typed = selectToolPart(call, tool);

      expect(typed, isNotNull);
      expect(typed!.name, 'getWeather');
      expect(typed.toolCallId, 'call-1');
      expect(typed.input, <String, dynamic>{'city': 'Paris'});
      expect(typed.output, const WeatherOutput(21));
      expect(typed.hasInput, isTrue);
      expect(typed.hasOutput, isTrue);
    });

    test('returns null for a different tool name', () {
      final call = AssistantPart.tool(
        id: 'call-1',
        name: 'getWeather',
        input: <String, dynamic>{'city': 'Paris'},
      );

      expect(selectToolPart(call, _weatherTool()), isNotNull);
      expect(
        selectToolPart(
          call,
          ClientTool<WeatherInput, WeatherOutput>(
            name: 'otherTool',
            execute: (input, context) => const WeatherOutput(1),
          ),
        ),
        isNull,
      );
    });

    test('rejects an unrelated separate tool result', () {
      final call = AssistantPart.tool(id: 'call-1', name: 'getWeather');
      final result =
          AssistantPart(type: 'tool-result', toolCallId: 'call-other');
      expect(() => selectToolPart(call, _weatherTool(), result: result),
          throwsArgumentError);
    });

    test('uses a separate tool-result part output and preserves presence', () {
      final call = AssistantPart.tool(
        id: 'call-1',
        name: 'getWeather',
        input: <String, dynamic>{'city': 'Paris'},
      );
      final result = AssistantPart(
        type: 'tool-result',
        toolCallId: 'call-1',
        output: const WeatherOutput(23),
        state: 'complete',
        outcome: 'success',
      );

      final typed = selectToolPart(call, _weatherTool(), result: result);

      expect(typed, isNotNull);
      expect(typed!.hasOutput, isTrue);
      expect(typed.output, const WeatherOutput(23));
      expect(typed.result, same(result));
      expect(typed.part, same(call));
    });

    test('distinguishes an explicit null output from an absent output', () {
      final nullableTool = ClientTool<WeatherInput, WeatherOutput?>(
        name: 'getWeather',
        execute: (input, context) => null,
      );
      final nullOutput = AssistantPart.tool(
        id: 'call-null',
        name: 'getWeather',
        input: <String, dynamic>{'city': 'Paris'},
        output: null,
      );
      final absentOutput = AssistantPart.tool(
        id: 'call-absent',
        name: 'getWeather',
        input: <String, dynamic>{'city': 'Paris'},
      );

      final typedNull = selectToolPart(nullOutput, nullableTool);
      final typedAbsent = selectToolPart(absentOutput, nullableTool);

      expect(typedNull!.hasOutput, isTrue);
      expect(typedNull.output, isNull);
      expect(typedAbsent!.hasOutput, isFalse);
      expect(typedAbsent.output, isNull);
    });
  });

  group('typed UI results and structured output', () {
    test('exposes tool-result outcome and typed output', () {
      final part = AssistantPart(
        type: 'tool-result',
        toolCallId: 'call-1',
        output: const WeatherOutput(21),
        outcome: 'denied',
        state: 'complete',
      );

      final typed = selectToolResult<WeatherOutput>(part);

      expect(typed, isNotNull);
      expect(typed!.output, const WeatherOutput(21));
      expect(typed.hasOutput, isTrue);
      expect(typed.outcome, 'denied');
      expect(typed.denied, isTrue);
      expect(typed.errored, isFalse);
    });

    test('keeps null tool-result output and signatures on thinking parts', () {
      final result = AssistantPart(
        type: 'tool-result',
        toolCallId: 'call-null',
        output: null,
        outcome: 'success',
      );
      final typed = selectToolResult<WeatherOutput?>(result);
      expect(typed!.hasOutput, isTrue);
      expect(typed.output, isNull);

      final thinking = AssistantPart.fromJson(<String, dynamic>{
        'type': 'thinking',
        'id': 'thought-1',
        'content': 'checking',
        'signature': 'sig-1',
        'redacted': false,
        'futureField': 'kept',
      });
      expect(thinking.signature, 'sig-1');
      expect(thinking.redacted, isFalse);
      expect(thinking.toJson()['signature'], 'sig-1');
      expect(thinking.toJson()['futureField'], 'kept');
    });

    test('exposes typed structured data, partial data and raw JSON', () {
      final part = AssistantPart(
        type: 'structured-output',
        structuredStatus: 'complete',
        raw: '{"title":"Pizza","servings":2}',
        data: <String, dynamic>{'title': 'Pizza', 'servings': 2},
        partial: <String, dynamic>{'title': 'Pizza'},
      );

      final typed = selectStructuredPart<Map<String, Object?>>(part);

      expect(typed, isNotNull);
      expect(typed!.status, 'complete');
      expect(typed.raw, '{"title":"Pizza","servings":2}');
      expect(typed.hasData, isTrue);
      expect(typed.data, <String, Object?>{'title': 'Pizza', 'servings': 2});
      expect(typed.hasPartial, isTrue);
      expect(typed.partial, <String, Object?>{'title': 'Pizza'});
    });

    test('returns null for the wrong part type', () {
      expect(selectStructuredPart<Object>(AssistantPart.text('x')), isNull);
      expect(selectToolResult<Object>(AssistantPart.text('x')), isNull);
      expect(selectTextPart(AssistantPart.text('x')), isNotNull);
      expect(selectTextPart(AssistantPart(type: 'activity')), isNull);
    });

    test('preserves unknown wire fields through a typed tool view', () {
      final part = AssistantPart.fromJson(<String, dynamic>{
        'type': 'tool-call',
        'id': 'call-1',
        'name': 'getWeather',
        'arguments': '{"city":"Paris"}',
        'input': <String, dynamic>{'city': 'Paris'},
        'output': null,
        'state': 'complete',
        'futureField': 'kept',
        'futureNested': <String, dynamic>{'x': 1},
      });
      final typed = selectToolPart(
        part,
        ClientTool<WeatherInput, WeatherOutput?>(
          name: 'getWeather',
          execute: (input, context) => null,
        ),
      );

      expect(typed, isNotNull);
      expect(typed!.hasOutput, isTrue);
      expect(typed.output, isNull);
      final wire = part.toJson();
      expect(wire['futureField'], 'kept');
      expect(wire['futureNested'], <String, dynamic>{'x': 1});
    });

    test('exposes text and activity fields without dynamic casts', () {
      final text = selectTextPart(AssistantPart.text('hello'));
      expect(text!.content, 'hello');

      final activity = selectActivityPart(
        AssistantPart(
          type: 'activity',
          activityType: 'SEARCH',
          activityContent: <String, dynamic>{'query': 'pizza'},
        ),
      );
      expect(activity, isNotNull);
      expect(activity!.activityType, 'SEARCH');
      expect(activity.content, <String, dynamic>{'query': 'pizza'});
    });
  });

  group('typed UI interrupts', () {
    ChatInterrupt planInterrupt() => ChatInterrupt(
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

    test('binds payload and response to an explicit registered definition', () {
      final interrupt = planInterrupt();
      final typed =
          selectRegisteredInterrupt<Map<String, dynamic>, WeatherOutput>(
        interrupt,
        definitionId: 'choosePlan',
      );

      expect(typed, isNotNull);
      expect(typed!.definitionId, 'choosePlan');
      expect(typed.hasPayload, isTrue);
      expect(typed.payload, <String, dynamic>{'title': 'Pizza'});
      expect(typed.canResolve, isTrue);

      final resolution = typed.resolve(const WeatherOutput(1));
      expect(resolution, isA<Map>());
      expect((resolution as Map)['payload'], const WeatherOutput(1));
    });

    test('rejects a different registered definition and non-generic kinds', () {
      final interrupt = planInterrupt();
      expect(
        selectRegisteredInterrupt<Map<String, dynamic>, WeatherOutput>(
          interrupt,
          definitionId: 'otherPlan',
        ),
        isNull,
      );

      final unbound = ChatInterrupt(
        id: 'foreign',
        kind: 'unbound',
        reason: 'foreign_pause',
        threadId: 'thread-1',
        interruptedRunId: 'run-1',
        generation: 1,
        canResolve: false,
      );
      expect(
        selectRegisteredInterrupt<Object, Object>(unbound),
        isNull,
      );
    });

    test('keeps tool-approval kind and toolName readable', () {
      final approval = ChatInterrupt(
        id: 'approval-1',
        kind: 'tool-approval',
        reason: 'approval_requested',
        toolName: 'purchaseItem',
        toolCallId: 'call-1',
        threadId: 'thread-1',
        interruptedRunId: 'run-1',
        generation: 1,
      );

      expect(approval.kind, 'tool-approval');
      expect(approval.toolName, 'purchaseItem');
      expect(
        selectRegisteredInterrupt<Object, Object>(approval),
        isNull,
      );
    });

    test('rejects a present payload with the wrong explicit type', () {
      expect(() => selectRegisteredInterrupt<int, String>(planInterrupt()),
          throwsA(isA<TypeError>()));
    });

    test('does not fake a payload when the interrupt has none', () {
      final interrupt = ChatInterrupt(
        id: 'interrupt-2',
        kind: 'generic',
        reason: 'choose',
        threadId: 'thread-1',
        interruptedRunId: 'run-1',
        generation: 1,
        definitionId: 'choosePlan',
      );
      final typed = selectRegisteredInterrupt<Map<String, dynamic>, String>(
        interrupt,
      );

      expect(typed, isNotNull);
      expect(typed!.hasPayload, isFalse);
      expect(typed.payload, isNull);
    });
  });
}
