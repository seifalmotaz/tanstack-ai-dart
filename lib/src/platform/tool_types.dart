import 'dart:async';

import '../cancellation.dart';

export '../cancellation.dart' show CancellationSignal;

/// Pure-Dart counterpart of the `@tanstack/ai/client` tool/schema surface used
/// by the platform ports.
///
/// Browser-only schema libraries are not available here. A [ToolSchema] is
/// either raw JSON Schema (passes through unchanged) or a host-provided
/// validator that mirrors the Standard Schema contract.

class SchemaIssue {
  final String message;
  final List<String>? path;

  const SchemaIssue(this.message, {this.path});
}

class SchemaValidationResult {
  final bool success;
  final Object? data;
  final List<SchemaIssue> issues;

  const SchemaValidationResult.success(this.data)
      : success = true,
        issues = const <SchemaIssue>[];

  const SchemaValidationResult.failure(this.issues)
      : success = false,
        data = null;
}

/// Schema input accepted by [ClientTool].
///
/// Raw maps/lists are treated as JSON Schema and passed through. A
/// [StandardSchema] delegates validation and can expose a JSON Schema view.
abstract class ToolSchema {
  const ToolSchema();

  Object? get jsonSchema;

  Future<SchemaValidationResult> validate(Object? value);
}

class RawJsonSchema extends ToolSchema {
  final Object? schema;

  const RawJsonSchema(this.schema);

  @override
  Object? get jsonSchema => schema;

  @override
  Future<SchemaValidationResult> validate(Object? value) async =>
      SchemaValidationResult.success(value);
}

/// Host-provided Standard Schema equivalent.
///
/// The callback may transform the value; transformed values are passed to the
/// tool execute function and the output validator, matching upstream.
class StandardSchema extends ToolSchema {
  final Object? schema;
  final FutureOr<SchemaValidationResult> Function(Object? value) validator;

  const StandardSchema(this.validator, {this.schema});

  @override
  Object? get jsonSchema => schema;

  @override
  Future<SchemaValidationResult> validate(Object? value) async =>
      validator(value);
}

ToolSchema? asToolSchema(Object? schema) {
  if (schema == null || schema is ToolSchema) return schema as ToolSchema?;
  if (schema is Map || schema is List) return RawJsonSchema(schema);
  return RawJsonSchema(schema);
}

Object? convertSchemaToJsonSchema(Object? schema) {
  if (schema is ToolSchema) return schema.jsonSchema;
  return schema;
}

Future<SchemaValidationResult> validateWithSchema(
  Object? schema,
  Object? value,
) {
  final typed = asToolSchema(schema);
  if (typed == null) return Future.value(SchemaValidationResult.success(value));
  return typed.validate(value);
}

class ToolCallContext {
  final CancellationSignal? abortSignal;
  final Object? context;
  final void Function()? emitCustomEvent;

  const ToolCallContext({
    this.abortSignal,
    this.context,
    this.emitCustomEvent,
  });
}

typedef ClientToolExecute<TInput, TOutput> = FutureOr<TOutput> Function(
  TInput input,
  ToolCallContext context,
);

/// Executable client tool. Mirrors the upstream `AnyClientTool` runtime shape.
///
/// `TInput` / `TOutput` are the typed callback contract. Raw `ClientTool`
/// (no type arguments) remains `ClientTool<dynamic, dynamic>` for backward
/// compatibility. Dart has no conditional mapped types, so typed callers
/// annotate the execute callback or supply type arguments; the schema still
/// controls runtime validation.
class ClientTool<TInput, TOutput> {
  final String name;
  final String description;
  final ToolSchema? inputSchema;
  final ToolSchema? outputSchema;
  final bool needsApproval;
  final Object? metadata;
  final ClientToolExecute<TInput, TOutput>? execute;

  ClientTool({
    required this.name,
    this.description = '',
    Object? inputSchema,
    Object? outputSchema,
    this.needsApproval = false,
    this.metadata,
    this.execute,
    Object? approvalSchema,
  })  : inputSchema = asToolSchema(inputSchema),
        outputSchema = asToolSchema(outputSchema) {
    if (approvalSchema != null) {
      _approvalSchemas[this] = approvalSchema;
    }
  }

  bool get hasExecute => execute != null;

  /// Dispatch through the reified generic instance without erasing callback types.
  FutureOr<Object?> invoke(Object? input, ToolCallContext context) {
    final callback = execute;
    if (callback == null) {
      throw StateError('Tool $name has no execute callback');
    }
    return callback(input as TInput, context);
  }
}

final Expando<Object> _approvalSchemas = Expando<Object>('approvalSchema');

/// Approval schema for a [ClientTool].
///
/// Stored outside the class so implementing classes (including the legacy
/// `ChatClientTool`) keep compiling; `ChatClientTool` can expose the same
/// option when its owner adds it.
extension ClientToolApprovalSchema on ClientTool<dynamic, dynamic> {
  Object? get approvalSchema => _approvalSchemas[this];
}

/// Read an approval schema from any tool shape, including a legacy tool that
/// declares its own `approvalSchema` member.
Object? clientToolApprovalSchema(ClientTool<dynamic, dynamic> tool) {
  try {
    final dynamic value = (tool as dynamic).approvalSchema;
    if (value != null) return value;
  } catch (_) {
    // Legacy classes do not declare the member; use the side table.
  }
  return _approvalSchemas[tool];
}

/// Build a tool list while retaining its explicit Dart element type.
/// Dart uses a list argument in place of JavaScript's variadic tuple.
List<TTool> clientTools<TTool extends ClientTool>(List<TTool> tools) =>
    List<TTool>.of(tools);
