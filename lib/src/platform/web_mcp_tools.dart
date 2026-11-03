import 'dart:async';
import 'dart:convert';

import 'tool_types.dart';

/// Ported from `packages/ai-client/src/web-mcp-tools.ts`.
///
/// `document.modelContext` is a browser-only API. The package exposes
/// [WebMcpPlatform] and never touches `document` directly. Without an injected
/// platform, registration is a no-op and reads return an empty list, matching
/// the upstream "unsupported browser" behavior.

class WebMcpToolAnnotations {
  final bool? readOnlyHint;
  final bool? untrustedContentHint;

  const WebMcpToolAnnotations({
    this.readOnlyHint,
    this.untrustedContentHint,
  });

  Map<String, dynamic> toJson() => {
        if (readOnlyHint != null) 'readOnlyHint': readOnlyHint,
        if (untrustedContentHint != null)
          'untrustedContentHint': untrustedContentHint,
      };
}

class WebMcpToolOptions {
  final String? title;
  final WebMcpToolAnnotations? annotations;

  const WebMcpToolOptions({this.title, this.annotations});
}

class WebMcpPageTool {
  final String name;
  final String? title;
  final String description;
  final Object? inputSchema;
  final String origin;
  final WebMcpToolAnnotations? annotations;

  const WebMcpPageTool({
    required this.name,
    this.title,
    required this.description,
    this.inputSchema,
    this.origin = '',
    this.annotations,
  });
}

class WebMcpRegisteredTool {
  final String name;
  final String? title;
  final String description;
  final Object? inputSchema;
  final WebMcpToolAnnotations? annotations;
  final Future<Object?> Function(
    Object? input, [
    CancellationSignal? signal,
  ]) execute;

  const WebMcpRegisteredTool({
    required this.name,
    this.title,
    required this.description,
    this.inputSchema,
    this.annotations,
    required this.execute,
  });
}

abstract class WebMcpModelContext {
  Future<void> registerTool(
    WebMcpRegisteredTool tool, {
    required CancellationSignal signal,
  });
}

abstract class WebMcpToolReader {
  Future<List<WebMcpPageTool>> getTools();
  Future<String> executeTool(
    WebMcpPageTool tool,
    Object? input, {
    CancellationSignal? signal,
  });
  Stream<void> get onToolChange;
}

abstract class WebMcpPlatform {
  bool get isSecureContext;
  WebMcpModelContext? get registrationContext;
  WebMcpToolReader? get readerContext;
}

class _UnavailableWebMcpPlatform implements WebMcpPlatform {
  const _UnavailableWebMcpPlatform();

  @override
  bool get isSecureContext => false;

  @override
  WebMcpModelContext? get registrationContext => null;

  @override
  WebMcpToolReader? get readerContext => null;
}

class RegisterWebMCPToolsOptions {
  final CancellationSignal signal;

  /// Per-tool options keyed by tool name. TypeScript constrains these keys to
  /// the tool list with a mapped type; Dart cannot express that constraint, so
  /// keys are runtime strings and values stay typed.
  final Map<String, WebMcpToolOptions>? toolOptions;
  final Object? context;

  const RegisterWebMCPToolsOptions({
    required this.signal,
    this.toolOptions,
    this.context,
  });
}

class GetWebMCPToolsOptions {
  final bool Function(WebMcpPageTool tool)? filter;

  const GetWebMCPToolsOptions({this.filter});
}

class SubscribeWebMCPToolsOptions extends GetWebMCPToolsOptions {
  final CancellationSignal signal;
  final void Function(Object error)? onError;

  const SubscribeWebMCPToolsOptions({
    required this.signal,
    super.filter,
    this.onError,
  });
}

final RegExp _validToolName = RegExp(r'^[A-Za-z0-9_.-]{1,128}$');

bool _requiresNonObjectInput(Object? jsonSchema) {
  if (jsonSchema is! Map) return false;
  final type = jsonSchema['type'];
  if (type is String) return type != 'object';
  if (type is List) return !type.contains('object');
  return false;
}

Future<Object?> _validateSchemaValue(Object? schema, Object? value) async {
  final result = await validateWithSchema(schema, value);
  if (result.success) return result.data;
  throw StateError(
    'Validation failed: ${result.issues.map((issue) => issue.message).join(', ')}',
  );
}

Future<void> registerWebMCPTools(
  List<ClientTool> tools,
  RegisterWebMCPToolsOptions options, {
  WebMcpPlatform platform = const _UnavailableWebMcpPlatform(),
}) async {
  if (!platform.isSecureContext) return;
  final context = platform.registrationContext;
  if (context == null) return;
  if (tools.isEmpty) return;

  final names = <String>{};
  final webTools = <WebMcpRegisteredTool>[];
  for (final tool in tools) {
    if (!_validToolName.hasMatch(tool.name)) {
      throw StateError(
        'WebMCP tool name "${tool.name}" must contain 1 to 128 ASCII letters, '
        'numbers, underscores, hyphens, or periods.',
      );
    }
    if (names.contains(tool.name)) {
      throw StateError('Duplicate WebMCP tool name "${tool.name}".');
    }
    if (tool.description.trim().isEmpty) {
      throw StateError('WebMCP tool "${tool.name}" must have a description.');
    }
    final execute = tool.hasExecute ? tool.invoke : null;
    if (execute == null) {
      throw StateError(
          'WebMCP tool "${tool.name}" must have an execute handler.');
    }
    if (tool.needsApproval) {
      throw StateError(
        'WebMCP tool "${tool.name}" cannot use needsApproval: true.',
      );
    }
    final inputSchema = tool.inputSchema;
    final outputSchema = tool.outputSchema;
    final convertedInputSchema = convertSchemaToJsonSchema(inputSchema);
    if (_requiresNonObjectInput(convertedInputSchema)) {
      throw StateError(
        'WebMCP tool "${tool.name}" input schema must accept an object.',
      );
    }
    names.add(tool.name);
    final toolOptions = options.toolOptions?[tool.name];
    final capturedInput = inputSchema;
    final capturedOutput = outputSchema;

    webTools.add(WebMcpRegisteredTool(
      name: tool.name,
      title: toolOptions?.title,
      description: tool.description,
      inputSchema: convertedInputSchema,
      annotations: toolOptions?.annotations,
      execute: (input, [signal]) async {
        final validatedInput = await _validateSchemaValue(capturedInput, input);
        final output = await Future<Object?>.sync(
          () => execute(
            validatedInput,
            ToolCallContext(
              abortSignal: signal,
              context: options.context,
              emitCustomEvent: () {},
            ),
          ),
        );
        return _validateSchemaValue(capturedOutput, output);
      },
    ));
  }

  final registrationSignal = CancellationSignal();
  void abortRegistration() => registrationSignal.abort(options.signal.reason);
  if (options.signal.isAborted) {
    abortRegistration();
  } else {
    options.signal.onAbort(abortRegistration);
  }

  try {
    for (final tool in webTools) {
      if (registrationSignal.isAborted) {
        throw registrationSignal.reason ?? StateError('registration aborted');
      }
      await context.registerTool(tool, signal: registrationSignal);
    }
  } catch (error) {
    registrationSignal.abort(error);
    rethrow;
  }
}

Future<List<ClientTool>> getWebMCPTools(
    [GetWebMCPToolsOptions options = const GetWebMCPToolsOptions(),
    WebMcpPlatform platform = const _UnavailableWebMcpPlatform()]) async {
  final reader = platform.isSecureContext ? platform.readerContext : null;
  if (reader == null) return <ClientTool>[];

  final pageTools = await reader.getTools();
  final names = <String>{};
  final tools = <ClientTool>[];
  for (final tool in pageTools) {
    if (options.filter != null && !options.filter!(tool)) continue;
    if (names.contains(tool.name)) {
      throw StateError(
        'Duplicate WebMCP tool name "${tool.name}". Use a filter or register '
        'tools with unique names.',
      );
    }
    names.add(tool.name);
    tools.add(ClientTool(
      name: tool.name,
      description: tool.description,
      inputSchema: tool.inputSchema ?? const {'type': 'object'},
      execute: (input, context) async {
        final result = await reader.executeTool(
          tool,
          input,
          signal: context.abortSignal,
        );
        try {
          return jsonDecode(result);
        } catch (_) {
          return result;
        }
      },
    ));
  }
  return tools;
}

void subscribeWebMCPTools(
  void Function(List<ClientTool> tools) listener,
  SubscribeWebMCPToolsOptions options, {
  WebMcpPlatform platform = const _UnavailableWebMcpPlatform(),
}) {
  if (options.signal.isAborted) return;
  final reader = platform.isSecureContext ? platform.readerContext : null;
  if (reader == null) {
    listener(<ClientTool>[]);
    return;
  }

  var latestRead = 0;
  void refresh() {
    final read = ++latestRead;
    bool isCurrent() => read == latestRead && !options.signal.isAborted;
    readWebMcpTools(reader, options).then(
      (tools) {
        if (isCurrent()) listener(tools);
      },
      onError: (Object error, StackTrace _) {
        if (isCurrent()) options.onError?.call(error);
      },
    );
  }

  final subscription = reader.onToolChange.listen((_) => refresh());
  options.signal.onAbort(() {
    unawaited(subscription.cancel());
  });
  refresh();
}

Future<List<ClientTool>> readWebMcpTools(
  WebMcpToolReader reader,
  GetWebMCPToolsOptions? options,
) =>
    getWebMCPTools(
        options ?? const GetWebMCPToolsOptions(), _ReaderPlatform(reader));

class _ReaderPlatform implements WebMcpPlatform {
  final WebMcpToolReader reader;

  _ReaderPlatform(this.reader);

  @override
  bool get isSecureContext => true;

  @override
  WebMcpModelContext? get registrationContext => null;

  @override
  WebMcpToolReader? get readerContext => reader;
}
