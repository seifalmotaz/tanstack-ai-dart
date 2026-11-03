// Ported from
// packages/ai-client/tests/web-mcp-tools.test.ts
// and packages/ai-client/tests/page-web-mcp-tools.test.ts
import 'dart:async';

import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

class FakeModelContext implements WebMcpModelContext {
  FakeModelContext({this.failOn});

  final String? failOn;
  final Map<String, WebMcpRegisteredTool> tools = {};

  @override
  Future<void> registerTool(
    WebMcpRegisteredTool tool, {
    required CancellationSignal signal,
  }) async {
    if (signal.isAborted) throw signal.reason ?? StateError('aborted');
    if (tool.name == failOn) {
      throw StateError('${tool.name} registration failed');
    }
    if (tools.containsKey(tool.name)) {
      throw StateError('Tool ${tool.name} is already registered');
    }
    tools[tool.name] = tool;
    signal.onAbort(() => tools.remove(tool.name));
  }
}

class FakeReader implements WebMcpToolReader {
  FakeReader(this.tools);

  List<WebMcpPageTool> tools;
  final StreamController<void> changes = StreamController<void>.broadcast();
  final List<WebMcpPageTool> executed = <WebMcpPageTool>[];
  final List<Object?> inputs = <Object?>[];
  Object? Function(WebMcpPageTool tool, Object? input)? execute;
  Object? getToolsError;
  Completer<List<WebMcpPageTool>>? pendingGet;

  @override
  Stream<void> get onToolChange => changes.stream;

  @override
  Future<List<WebMcpPageTool>> getTools() {
    final pending = pendingGet;
    if (pending != null) return pending.future;
    final error = getToolsError;
    if (error != null) return Future.error(error);
    return Future.value(List<WebMcpPageTool>.of(tools));
  }

  @override
  Future<String> executeTool(
    WebMcpPageTool tool,
    Object? input, {
    CancellationSignal? signal,
  }) async {
    executed.add(tool);
    inputs.add(input);
    final result =
        execute != null ? execute!(tool, input) : '{"temperature":21}';
    return result is String ? result : '$result';
  }

  void changeTools(List<WebMcpPageTool> next) {
    tools = next;
    changes.add(null);
  }
}

class FakePlatform implements WebMcpPlatform {
  FakePlatform({this.context, this.reader, this.secure = true});

  final FakeModelContext? context;
  final FakeReader? reader;
  bool secure;

  @override
  bool get isSecureContext => secure;

  @override
  WebMcpModelContext? get registrationContext => context;

  @override
  WebMcpToolReader? get readerContext => reader;
}

const weather = WebMcpPageTool(
  name: 'get_weather',
  description: 'Get the weather',
  inputSchema: {
    'type': 'object',
    'properties': {
      'city': {'type': 'string'},
    },
  },
  origin: 'https://example.com',
);

const other = WebMcpPageTool(
  name: 'other_tool',
  description: 'A tool from another origin',
  origin: 'https://other.example',
);

ToolSchema objectSchema({
  bool rejectInput = false,
  Object? Function(Object? value)? transform,
  String property = 'value',
}) =>
    StandardSchema(
      (value) {
        if (rejectInput) {
          return const SchemaValidationResult.failure([
            SchemaIssue('Invalid input'),
          ]);
        }
        if (value is Map && value[property] != null) {
          return SchemaValidationResult.success(
            transform != null ? transform(value) : value,
          );
        }
        return const SchemaValidationResult.failure([
          SchemaIssue('Validation failed'),
        ]);
      },
      schema: {
        'type': 'object',
        'properties': {
          property: {'type': 'string'},
        },
        'required': [property],
      },
    );

void main() {
  group('registerWebMCPTools', () {
    test('registers, executes, and removes an executable client tool',
        () async {
      final context = FakeModelContext();
      final platform = FakePlatform(context: context);
      final lifecycle = CancellationSignal();
      final execution = CancellationSignal();
      var emitted = 0;
      final tool = ClientTool(
        name: 'echo',
        description: 'Echo a value',
        inputSchema: objectSchema(),
        outputSchema: StandardSchema(
          (value) {
            if (value is Map &&
                value['value'] is String &&
                value['tenantId'] is String &&
                value['aborted'] is bool &&
                value['hasToolCallId'] is bool) {
              return SchemaValidationResult.success(value);
            }
            return const SchemaValidationResult.failure([
              SchemaIssue('Invalid output'),
            ]);
          },
        ),
        execute: (input, toolContext) {
          toolContext.emitCustomEvent?.call();
          emitted++;
          final map = input as Map;
          return {
            'value': map['value'],
            'tenantId': toolContext.context,
            'aborted': identical(toolContext.abortSignal, execution),
            'hasToolCallId': false,
          };
        },
      );

      await registerWebMCPTools(
        [tool],
        RegisterWebMCPToolsOptions(
          signal: lifecycle,
          context: 'tenant-1',
          toolOptions: const {
            'echo': WebMcpToolOptions(
              title: 'Echo value',
              annotations: WebMcpToolAnnotations(
                readOnlyHint: true,
                untrustedContentHint: true,
              ),
            ),
          },
        ),
        platform: platform,
      );

      final registered = context.tools['echo']!;
      expect(registered.name, 'echo');
      expect(registered.title, 'Echo value');
      expect(registered.description, 'Echo a value');
      expect(registered.annotations?.readOnlyHint, isTrue);
      expect(registered.annotations?.untrustedContentHint, isTrue);
      expect(registered.inputSchema, {
        'type': 'object',
        'properties': {
          'value': {'type': 'string'},
        },
        'required': ['value'],
      });
      expect(
        await registered.execute({'value': 'hello'}, execution),
        {
          'value': 'hello',
          'tenantId': 'tenant-1',
          'aborted': true,
          'hasToolCallId': false,
        },
      );
      expect(emitted, 1);

      lifecycle.abort();
      expect(context.tools, isEmpty);
    });

    test('executes when the host omits the execution options argument',
        () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      final tool = ClientTool(
        name: 'host_omits_options',
        description: 'Run without host options',
        inputSchema: objectSchema(),
        outputSchema: objectSchema(),
        execute: (input, context) => input,
      );

      await registerWebMCPTools(
        [tool],
        RegisterWebMCPToolsOptions(signal: lifecycle),
        platform: FakePlatform(context: context),
      );
      final registered = context.tools['host_omits_options']!;

      expect(await registered.execute({'value': 'ok'}), {'value': 'ok'});
    });

    test('validates Standard Schema input before execution', () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      var executions = 0;
      final tool = ClientTool(
        name: 'validate_input',
        description: 'Validate input',
        inputSchema: objectSchema(rejectInput: true),
        execute: (input, context) {
          executions++;
          return {'ok': true};
        },
      );

      await registerWebMCPTools(
        [tool],
        RegisterWebMCPToolsOptions(signal: lifecycle),
        platform: FakePlatform(context: context),
      );
      final registered = context.tools['validate_input']!;

      await expectLater(
        registered.execute({'value': 1}, CancellationSignal()),
        throwsA(predicate((error) => '$error'.contains('Validation failed'))),
      );
      expect(executions, 0);
    });

    test('validates Standard Schema output after execution', () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      final tool = ClientTool(
        name: 'validate_output',
        description: 'Validate output',
        outputSchema: StandardSchema(
          (value) => value is Map && value['ok'] is bool
              ? SchemaValidationResult.success(value)
              : const SchemaValidationResult.failure([
                  SchemaIssue('Expected a boolean ok value'),
                ]),
        ),
        execute: (input, context) => {'ok': 'no'},
      );

      await registerWebMCPTools(
        [tool],
        RegisterWebMCPToolsOptions(signal: lifecycle),
        platform: FakePlatform(context: context),
      );
      final registered = context.tools['validate_output']!;

      await expectLater(
        registered.execute({}, CancellationSignal()),
        throwsA(predicate((error) => '$error'.contains('Validation failed'))),
      );
    });

    test('passes transformed Standard Schema values through execution',
        () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      final received = <Object?>[];
      final tool = ClientTool(
        name: 'transform_values',
        description: 'Transform values',
        inputSchema: objectSchema(
          transform: (value) => {
            'value': ((value as Map)['value'] as String).trim(),
          },
        ),
        outputSchema: StandardSchema(
          (value) => SchemaValidationResult.success({
            'result': ((value as Map)['value'] as String).toUpperCase(),
          }),
        ),
        execute: (input, context) {
          received.add(input);
          return {'value': '${(input as Map)['value']}!'};
        },
      );

      await registerWebMCPTools(
        [tool],
        RegisterWebMCPToolsOptions(signal: lifecycle),
        platform: FakePlatform(context: context),
      );
      final registered = context.tools['transform_values']!;

      expect(
        await registered.execute({'value': '  hello  '}, CancellationSignal()),
        {'result': 'HELLO!'},
      );
      expect(received, [
        {'value': 'hello'},
      ]);
    });

    test('uses the schemas captured during registration', () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      final inputSchema = objectSchema();
      final outputSchema = objectSchema();
      final tool = ClientTool(
        name: 'captured_schemas',
        description: 'Use captured schemas',
        inputSchema: inputSchema,
        outputSchema: outputSchema,
        execute: (input, context) => input,
      );

      await registerWebMCPTools(
        [tool],
        RegisterWebMCPToolsOptions(signal: lifecycle),
        platform: FakePlatform(context: context),
      );
      final registered = context.tools['captured_schemas']!;

      expect(
        await registered.execute({'value': 'original'}, CancellationSignal()),
        {'value': 'original'},
      );
    });

    test('leaves raw JSON Schema validation to the client handler', () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      final tool = ClientTool(
        name: 'raw_schema',
        description: 'Use a raw schema',
        inputSchema: const RawJsonSchema({
          'type': ['object', 'null'],
          'properties': {
            'value': {'type': 'string'},
          },
          'required': ['value'],
        }),
        execute: (input, context) => input,
      );

      await registerWebMCPTools(
        [tool],
        RegisterWebMCPToolsOptions(signal: lifecycle),
        platform: FakePlatform(context: context),
      );
      final registered = context.tools['raw_schema']!;

      expect(
        await registered.execute({'value': 1}, CancellationSignal()),
        {'value': 1},
      );
    });

    test('rejects a scalar top-level input schema', () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      final tool = ClientTool(
        name: 'scalar_input',
        description: 'Use scalar input',
        inputSchema: const RawJsonSchema({'type': 'string'}),
        execute: (input, context) => input,
      );

      await expectLater(
        registerWebMCPTools(
          [tool],
          RegisterWebMCPToolsOptions(signal: lifecycle),
          platform: FakePlatform(context: context),
        ),
        throwsA(
          predicate(
            (error) => '$error'.contains('input schema must accept an object'),
          ),
        ),
      );
      expect(context.tools, isEmpty);
    });

    test('resolves without registration when WebMCP is unavailable', () async {
      final lifecycle = CancellationSignal();
      final tool = ClientTool(
        name: 'unsupported',
        description: 'Do not register',
        execute: (input, context) => {'ok': true},
      );

      await registerWebMCPTools(
        [tool],
        RegisterWebMCPToolsOptions(signal: lifecycle),
        platform: const _UnavailableTestPlatform(),
      );
      await registerWebMCPTools(
        [tool],
        RegisterWebMCPToolsOptions(signal: lifecycle),
        platform: FakePlatform(secure: false),
      );
    });

    test('does not register tools for an already-aborted lifetime', () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      final reason = StateError('registration stopped');
      final tool = ClientTool(
        name: 'already_aborted',
        description: 'Do not register after abort',
        execute: (input, context) => {'ok': true},
      );
      lifecycle.abort(reason);

      await expectLater(
        registerWebMCPTools(
          [tool],
          RegisterWebMCPToolsOptions(signal: lifecycle),
          platform: FakePlatform(context: context),
        ),
        throwsA(same(reason)),
      );
      expect(context.tools, isEmpty);
    });

    test('does not link the lifecycle signal for an empty tool list', () async {
      final context = FakeModelContext();
      final lifecycle = _CountingSignal();

      await registerWebMCPTools(
        const <ClientTool>[],
        RegisterWebMCPToolsOptions(signal: lifecycle),
        platform: FakePlatform(context: context),
      );

      expect(lifecycle.listenerAdds, 0);
      expect(context.tools, isEmpty);
    });

    test('removes partial registrations when registration fails', () async {
      final context = FakeModelContext(failOn: 'second');
      final lifecycle = CancellationSignal();
      final first = ClientTool(
        name: 'first',
        description: 'First tool',
        execute: (input, context) => 'first',
      );
      final second = ClientTool(
        name: 'second',
        description: 'Second tool',
        execute: (input, context) => 'second',
      );

      await expectLater(
        registerWebMCPTools(
          [first, second],
          RegisterWebMCPToolsOptions(signal: lifecycle),
          platform: FakePlatform(context: context),
        ),
        throwsA(
          predicate((error) => '$error'.contains('second registration failed')),
        ),
      );
      expect(context.tools, isEmpty);
    });

    test("rejects 'a missing execute handler' before registration", () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      final tool = ClientTool(name: 'missing_execute', description: 'Missing');

      await expectLater(
        registerWebMCPTools(
          [tool],
          RegisterWebMCPToolsOptions(signal: lifecycle),
          platform: FakePlatform(context: context),
        ),
        throwsA(predicate((error) => '$error'.contains('execute'))),
      );
      expect(context.tools, isEmpty);
    });

    test("rejects 'an approval tool' before registration", () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      final tool = ClientTool(
        name: 'approval',
        description: 'Approval tool',
        needsApproval: true,
        execute: (input, context) => 'approved',
      );

      await expectLater(
        registerWebMCPTools(
          [tool],
          RegisterWebMCPToolsOptions(signal: lifecycle),
          platform: FakePlatform(context: context),
        ),
        throwsA(predicate((error) => '$error'.contains('needsApproval'))),
      );
    });

    test("rejects 'an invalid name' before registration", () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      final tool = ClientTool(
        name: 'invalid name',
        description: 'Invalid name',
        execute: (input, context) => 'invalid',
      );

      await expectLater(
        registerWebMCPTools(
          [tool],
          RegisterWebMCPToolsOptions(signal: lifecycle),
          platform: FakePlatform(context: context),
        ),
        throwsA(predicate((error) => '$error'.contains('WebMCP tool name'))),
      );
    });

    test("rejects 'a name longer than 128 characters' before registration",
        () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      final tool = ClientTool(
        name: 'a' * 129,
        description: 'Long name',
        execute: (input, context) => 'invalid',
      );

      await expectLater(
        registerWebMCPTools(
          [tool],
          RegisterWebMCPToolsOptions(signal: lifecycle),
          platform: FakePlatform(context: context),
        ),
        throwsA(predicate((error) => '$error'.contains('WebMCP tool name'))),
      );
    });

    test("rejects 'an empty description' before registration", () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      final tool = ClientTool(
        name: 'empty_description',
        description: '',
        execute: (input, context) => 'invalid',
      );

      await expectLater(
        registerWebMCPTools(
          [tool],
          RegisterWebMCPToolsOptions(signal: lifecycle),
          platform: FakePlatform(context: context),
        ),
        throwsA(predicate((error) => '$error'.contains('description'))),
      );
    });

    test('rejects duplicate names before registration', () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      final first = ClientTool(
        name: 'duplicate',
        description: 'First duplicate',
        execute: (input, context) => 'first',
      );
      final duplicate = ClientTool(
        name: 'duplicate',
        description: 'Second duplicate',
        execute: (input, context) => 'second',
      );

      await expectLater(
        registerWebMCPTools(
          [first, duplicate],
          RegisterWebMCPToolsOptions(signal: lifecycle),
          platform: FakePlatform(context: context),
        ),
        throwsA(
          predicate(
            (error) => '$error'.contains('Duplicate WebMCP tool name'),
          ),
        ),
      );
    });

    test('preserves a foreign registration with the same name', () async {
      final context = FakeModelContext();
      final lifecycle = CancellationSignal();
      final foreign = WebMcpRegisteredTool(
        name: 'foreign_owned',
        description: 'Foreign tool',
        execute: (input, [signal]) async => input,
      );
      context.tools[foreign.name] = foreign;
      final tool = ClientTool(
        name: 'foreign_owned',
        description: 'Conflicting tool',
        execute: (input, context) => 'local',
      );

      await expectLater(
        registerWebMCPTools(
          [tool],
          RegisterWebMCPToolsOptions(signal: lifecycle),
          platform: FakePlatform(context: context),
        ),
        throwsA(predicate((error) => '$error'.contains('already registered'))),
      );
      expect(identical(context.tools[foreign.name], foreign), isTrue);
    });
  });

  group('getWebMCPTools', () {
    test('converts page tools to client tools that run through executeTool',
        () async {
      final reader = FakeReader([weather]);
      final platform = FakePlatform(reader: reader);
      final execution = CancellationSignal();

      final tools = await getWebMCPTools(
        const GetWebMCPToolsOptions(),
        platform,
      );
      final tool = tools.single;

      expect(tool.name, 'get_weather');
      expect(tool.description, 'Get the weather');
      expect(tool.inputSchema?.jsonSchema, weather.inputSchema);
      expect(
        await tool.execute?.call(
            {'city': 'Sarajevo'},
            ToolCallContext(
              abortSignal: execution,
            )),
        {'temperature': 21},
      );
      expect(reader.executed, [weather]);
      expect(reader.inputs, [
        {'city': 'Sarajevo'},
      ]);
    });

    test('returns a result that is not JSON as a string', () async {
      final reader = FakeReader([other])..execute = (_, __) => 'plain text';
      final platform = FakePlatform(reader: reader);

      final tool = (await getWebMCPTools(
        const GetWebMCPToolsOptions(),
        platform,
      ))
          .single;

      expect(tool.inputSchema?.jsonSchema, {'type': 'object'});
      expect(
          await tool.execute?.call({}, const ToolCallContext()), 'plain text');
    });

    test('skips tools that the filter rejects', () async {
      final reader = FakeReader([weather, other]);

      final tools = await getWebMCPTools(
        GetWebMCPToolsOptions(
          filter: (tool) => tool.origin == 'https://example.com',
        ),
        FakePlatform(reader: reader),
      );

      expect(tools.map((tool) => tool.name), ['get_weather']);
    });

    test('returns an empty array without WebMCP', () async {
      expect(
        await getWebMCPTools(
          const GetWebMCPToolsOptions(),
          const _UnavailableTestPlatform(),
        ),
        isEmpty,
      );
      expect(
        await getWebMCPTools(
          const GetWebMCPToolsOptions(),
          FakePlatform(secure: false),
        ),
        isEmpty,
      );
    });

    test('rejects duplicate names from different frames after filtering',
        () async {
      final parentTool = WebMcpPageTool(
        name: weather.name,
        title: 'Parent weather',
        description: weather.description,
        inputSchema: weather.inputSchema,
        origin: weather.origin,
      );
      final frameTool = WebMcpPageTool(
        name: weather.name,
        title: 'Frame weather',
        description: weather.description,
        inputSchema: weather.inputSchema,
        origin: weather.origin,
      );
      final reader = FakeReader([parentTool, frameTool]);

      await expectLater(
        getWebMCPTools(
          const GetWebMCPToolsOptions(),
          FakePlatform(reader: reader),
        ),
        throwsA(predicate(
          (error) =>
              '$error'.contains('Duplicate WebMCP tool name "get_weather"'),
        )),
      );
      expect(reader.executed, isEmpty);

      final tools = await getWebMCPTools(
        GetWebMCPToolsOptions(
          filter: (tool) => tool.title == 'Parent weather',
        ),
        FakePlatform(reader: reader),
      );
      expect(tools, hasLength(1));
      await tools.single.execute?.call(
        {'city': 'Sarajevo'},
        const ToolCallContext(),
      );
      expect(reader.executed, [parentTool]);
    });

    test('rejects when getTools rejects', () async {
      final reader = FakeReader([])
        ..getToolsError = StateError('NotAllowedError');

      await expectLater(
        getWebMCPTools(
          const GetWebMCPToolsOptions(),
          FakePlatform(reader: reader),
        ),
        throwsA(predicate((error) => '$error'.contains('NotAllowedError'))),
      );
    });
  });

  group('subscribeWebMCPTools', () {
    test(
        'reports duplicate names without replacing the last good list and recovers',
        () async {
      final reader = FakeReader([weather]);
      final platform = FakePlatform(reader: reader);
      final lifecycle = CancellationSignal();
      final lists = <List<ClientTool>>[];
      final errors = <Object>[];
      subscribeWebMCPTools(
        lists.add,
        SubscribeWebMCPToolsOptions(
          signal: lifecycle,
          onError: errors.add,
        ),
        platform: platform,
      );
      await Future<void>.delayed(Duration.zero);
      expect(lists, hasLength(1));

      reader.changeTools([weather, weather]);
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
      expect('${errors.single}', contains('Duplicate WebMCP tool name'));
      expect(lists, hasLength(1));

      reader.changeTools([other]);
      await Future<void>.delayed(Duration.zero);
      expect(lists, hasLength(2));
      expect(lists.last.single.name, 'other_tool');
      lifecycle.abort();
    });

    test('sends the list now and after each toolchange until the signal aborts',
        () async {
      final reader = FakeReader([weather]);
      final platform = FakePlatform(reader: reader);
      final lifecycle = CancellationSignal();
      final lists = <List<ClientTool>>[];

      subscribeWebMCPTools(
        lists.add,
        SubscribeWebMCPToolsOptions(signal: lifecycle),
        platform: platform,
      );
      await Future<void>.delayed(Duration.zero);
      expect(lists, hasLength(1));
      expect(lists.last.map((tool) => tool.name), ['get_weather']);

      reader.changeTools([weather, other]);
      await Future<void>.delayed(Duration.zero);
      expect(lists, hasLength(2));
      expect(lists.last, hasLength(2));

      lifecycle.abort();
      reader.changeTools(<WebMcpPageTool>[]);
      await Future<void>.delayed(Duration.zero);
      expect(lists, hasLength(2));
    });

    test('ignores a read that finishes after a newer read', () async {
      final reader = FakeReader([]);
      final firstRead = Completer<List<WebMcpPageTool>>();
      reader.pendingGet = firstRead;
      final lifecycle = CancellationSignal();
      final lists = <List<ClientTool>>[];

      subscribeWebMCPTools(
        lists.add,
        SubscribeWebMCPToolsOptions(signal: lifecycle),
        platform: FakePlatform(reader: reader),
      );
      reader.pendingGet = null;
      reader.changeTools([other]);
      await Future<void>.delayed(Duration.zero);
      expect(lists, hasLength(1));

      firstRead.complete([weather]);
      await Future<void>.delayed(Duration.zero);
      expect(lists, hasLength(1));
      expect(lists.last.single.name, 'other_tool');
      lifecycle.abort();
    });

    test('reports read errors to onError', () async {
      final reader = FakeReader([])
        ..getToolsError = StateError('NotAllowedError');
      final lifecycle = CancellationSignal();
      final lists = <List<ClientTool>>[];
      final errors = <Object>[];

      subscribeWebMCPTools(
        lists.add,
        SubscribeWebMCPToolsOptions(
          signal: lifecycle,
          onError: errors.add,
        ),
        platform: FakePlatform(reader: reader),
      );

      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
      expect(lists, isEmpty);
      lifecycle.abort();
    });

    test('sends an empty list once without WebMCP', () {
      final lists = <List<ClientTool>>[];

      subscribeWebMCPTools(
        lists.add,
        SubscribeWebMCPToolsOptions(signal: CancellationSignal()),
        platform: FakePlatform(secure: false),
      );

      expect(lists, hasLength(1));
      expect(lists.single, isEmpty);
    });
  });
}

class _CountingSignal extends CancellationSignal {
  int listenerAdds = 0;

  @override
  void Function() onAbort(void Function() listener) {
    listenerAdds++;
    return super.onAbort(listener);
  }
}

class _UnavailableTestPlatform implements WebMcpPlatform {
  const _UnavailableTestPlatform();

  @override
  bool get isSecureContext => false;

  @override
  WebMcpModelContext? get registrationContext => null;

  @override
  WebMcpToolReader? get readerContext => null;
}
