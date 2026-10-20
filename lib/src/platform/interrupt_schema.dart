import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/dart.dart' show DartSha256;

import 'tool_types.dart';

// Port of @tanstack/ai `interrupt-serialization.ts`,
// `interrupt-definition.ts` schema hashing and
// `activities/chat/tools/approval-schema.ts`.
//
// This is the ownership boundary: the client compares the hashes it stamps on
// interrupt bindings against the schemas configured in this process. Raw JSON
// Schema is never compiled or validated here; it is carried and hashed as-is.

String _sha256Hex(String input) => const DartSha256()
    .hashSync(utf8.encode(input))
    .bytes
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

/// The built-in hash, prefixed so the algorithm is self-describing.
String defaultInterruptHash(String canonicalJson) =>
    'sha256:${_sha256Hex(canonicalJson)}';

/// Hash canonical JSON text. Must match the producer's hash exactly.
String digestInterruptJson(
  String canonicalJson, [
  String Function(String canonicalJson)? hash,
]) {
  return (hash ?? defaultInterruptHash)(canonicalJson);
}

String _jsString(String value) {
  final out = StringBuffer('"');
  for (var i = 0; i < value.length; i++) {
    final code = value.codeUnitAt(i);
    if (code == 0x22) {
      out.write(r'\"');
    } else if (code == 0x5C) {
      out.write(r'\\');
    } else if (code == 0x08) {
      out.write(r'\b');
    } else if (code == 0x09) {
      out.write(r'\t');
    } else if (code == 0x0A) {
      out.write(r'\n');
    } else if (code == 0x0C) {
      out.write(r'\f');
    } else if (code == 0x0D) {
      out.write(r'\r');
    } else if (code < 0x20) {
      out
        ..write(r'\u')
        ..write(code.toRadixString(16).padLeft(4, '0'));
    } else if (code >= 0xD800 && code <= 0xDBFF) {
      final next = i + 1 < value.length ? value.codeUnitAt(i + 1) : 0;
      if (next >= 0xDC00 && next <= 0xDFFF) {
        out
          ..writeCharCode(code)
          ..writeCharCode(next);
        i++;
      } else {
        out
          ..write(r'\u')
          ..write(code.toRadixString(16).padLeft(4, '0'));
      }
    } else if (code >= 0xDC00 && code <= 0xDFFF) {
      out
        ..write(r'\u')
        ..write(code.toRadixString(16).padLeft(4, '0'));
    } else {
      out.writeCharCode(code);
    }
  }
  out.write('"');
  return out.toString();
}

String _jsNumber(num value) {
  final double number = value.toDouble();
  if (!number.isFinite) {
    throw ArgumentError('Interrupt values must be JSON-compatible.');
  }
  if (number == 0) return '0';
  var text = number.toString();
  if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
  return text;
}

String _canonical(Object? value, Set<Object> active) {
  if (value == null) return 'null';
  if (value is String) return _jsString(value);
  if (value is bool) return value ? 'true' : 'false';
  if (value is num) return _jsNumber(value);
  if (value is List && value is! TypedData) {
    if (!active.add(value)) {
      throw ArgumentError('Interrupt values must not cycle.');
    }
    final items = <String>[
      for (var i = 0; i < value.length; i++) _canonical(value[i], active),
    ];
    active.remove(value);
    return '[${items.join(',')}]';
  }
  if (value is Map) {
    if (!active.add(value)) {
      throw ArgumentError('Interrupt values must not cycle.');
    }
    final keys = <String>[];
    for (final key in value.keys) {
      if (key is! String) {
        throw ArgumentError('Interrupt values must use plain JSON objects.');
      }
      keys.add(key);
    }
    keys.sort();
    final entries = <String>[
      for (final key in keys)
        '${_jsString(key)}:${_canonical(value[key], active)}',
    ];
    active.remove(value);
    return '{${entries.join(',')}}';
  }
  throw ArgumentError('Interrupt values must be JSON-compatible.');
}

/// Serialize like the pinned upstream `canonicalInterruptJson`.
///
/// Rejects values JSON cannot carry (functions, undefined, non-finite numbers,
/// cycles, non-plain objects). Object keys sort by UTF-16 code unit, matching
/// JavaScript's default `Array.prototype.sort`.
String canonicalInterruptJson(Object? value) =>
    _canonical(value, HashSet<Object>.identity());

class NormalizedSchemaInput {
  final Object? source;
  final StandardSchema? validator;
  final Map<String, dynamic>? jsonSchema;

  const NormalizedSchemaInput({
    required this.source,
    this.validator,
    this.jsonSchema,
  });
}

class NormalizedApprovalSchema {
  final NormalizedSchemaInput? approve;
  final NormalizedSchemaInput? reject;
  final Map<String, dynamic> responseSchema;
  final String responseSchemaHash;
  final String approvalSchemaHash;

  const NormalizedApprovalSchema({
    required this.approve,
    required this.reject,
    required this.responseSchema,
    required this.responseSchemaHash,
    required this.approvalSchemaHash,
  });

  Map<String, NormalizedSchemaInput?> get branches =>
      <String, NormalizedSchemaInput?>{
        'approve': approve,
        'reject': reject,
      };
}

const Set<String> _jsonSchemaKeywords = <String>{
  r'$schema',
  r'$id',
  r'$ref',
  r'$defs',
  'type',
  'properties',
  'required',
  'additionalProperties',
  'items',
  'oneOf',
  'anyOf',
  'allOf',
  'enum',
  'const',
  'format',
  'minimum',
  'maximum',
  'minLength',
  'maxLength',
  'pattern',
};

bool _isRawJsonSchema(Object? value) {
  if (value is! Map) return false;
  return value.keys
      .any((key) => key is String && _jsonSchemaKeywords.contains(key));
}

Map<String, dynamic>? _copyJsonSchema(Object? value) {
  if (value is! Map) return null;
  final out = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throw ArgumentError('Interrupt schema keys must be strings.');
    }
    out[key] = entry.value is Map
        ? _copyJsonSchema(entry.value)
        : entry.value is List
            ? _copyJsonList(entry.value as List)
            : entry.value;
  }
  return out;
}

List<dynamic> _copyJsonList(List<dynamic> value) => <dynamic>[
      for (final item in value)
        item is Map
            ? _copyJsonSchema(item)
            : item is List
                ? _copyJsonList(item)
                : item,
    ];

Map<String, dynamic>? _copyWithoutSchemaKeyword(Object? value) {
  final copied = _copyJsonSchema(value);
  if (copied == null) return null;
  copied.remove(r'$schema');
  return copied;
}

NormalizedSchemaInput? _schemaToWire(
  Object? source, {
  bool stripSchemaKeyword = false,
}) {
  if (source == null) return null;
  if (source is StandardSchema) {
    final json = source.jsonSchema;
    final wire = json == null
        ? null
        : stripSchemaKeyword
            ? _copyWithoutSchemaKeyword(json)
            : _copyJsonSchema(json);
    return NormalizedSchemaInput(
      source: source,
      validator: source,
      jsonSchema: wire,
    );
  }
  if (source is RawJsonSchema) {
    final json = source.jsonSchema;
    if (!_isRawJsonSchema(json)) {
      throw ArgumentError('Expected a supported SchemaInput.');
    }
    return NormalizedSchemaInput(
      source: source,
      jsonSchema: stripSchemaKeyword
          ? _copyWithoutSchemaKeyword(json)
          : _copyJsonSchema(json),
    );
  }
  if (source is ToolSchema) {
    final json = source.jsonSchema;
    if (json is Map) {
      final wire = stripSchemaKeyword
          ? _copyWithoutSchemaKeyword(json)
          : _copyJsonSchema(json);
      if (_isRawJsonSchema(wire)) {
        return NormalizedSchemaInput(source: source, jsonSchema: wire);
      }
    }
    throw ArgumentError('Expected a supported SchemaInput.');
  }
  if (_isRawJsonSchema(source)) {
    return NormalizedSchemaInput(
      source: source,
      jsonSchema: stripSchemaKeyword
          ? _copyWithoutSchemaKeyword(source)
          : _copyJsonSchema(source),
    );
  }
  throw ArgumentError('Expected a supported SchemaInput.');
}

Map<String, dynamic> _decisionEnvelope({
  required bool approved,
  required NormalizedSchemaInput? payload,
  required NormalizedSchemaInput? inputSchema,
}) {
  final properties = <String, dynamic>{
    'approved': <String, dynamic>{'const': approved},
  };
  final required = <String>['approved'];
  if (approved && inputSchema != null) {
    properties['editedArgs'] = inputSchema.jsonSchema ?? <String, dynamic>{};
  }
  if (payload != null) {
    properties['payload'] = payload.jsonSchema ?? <String, dynamic>{};
    required.add('payload');
  }
  return <String, dynamic>{
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  };
}

/// Port of upstream `normalizeApprovalSchema`.
NormalizedApprovalSchema normalizeApprovalSchema(
  Object? approvalSchema, [
  Object? inputSchema,
]) {
  final normalizedInput =
      inputSchema == null ? null : _schemaToWire(inputSchema);
  NormalizedSchemaInput? approve;
  NormalizedSchemaInput? reject;

  if (approvalSchema != null) {
    if (approvalSchema is StandardSchema || _isRawJsonSchema(approvalSchema)) {
      approve = _schemaToWire(approvalSchema);
      reject = approve;
    } else if (approvalSchema is ToolSchema) {
      approve = _schemaToWire(approvalSchema);
      reject = approve;
    } else if (_isApprovalBranchMap(approvalSchema)) {
      final map = approvalSchema as Map;
      approve = map['approve'] == null ? null : _schemaToWire(map['approve']);
      reject = map['reject'] == null ? null : _schemaToWire(map['reject']);
    } else {
      throw ArgumentError(
        'approvalSchema must be a SchemaInput or a nonempty map containing '
        'approve or reject.',
      );
    }
  }

  final responseSchema = <String, dynamic>{
    'oneOf': <dynamic>[
      _decisionEnvelope(
        approved: true,
        payload: approve,
        inputSchema: normalizedInput,
      ),
      _decisionEnvelope(
        approved: false,
        payload: reject,
        inputSchema: null,
      ),
    ],
  };
  final responseCanonical = canonicalInterruptJson(responseSchema);
  final approvalCanonical = canonicalInterruptJson(<String, dynamic>{
    'approve': approve?.jsonSchema,
    'reject': reject?.jsonSchema,
  });
  return NormalizedApprovalSchema(
    approve: approve,
    reject: reject,
    responseSchema: responseSchema,
    responseSchemaHash: digestInterruptJson(responseCanonical),
    approvalSchemaHash: digestInterruptJson(approvalCanonical),
  );
}

bool _isApprovalBranchMap(Object? value) {
  if (value is! Map) return false;
  if (value.isEmpty) return false;
  for (final entry in value.entries) {
    if (entry.key != 'approve' && entry.key != 'reject') return false;
    if (entry.value != null && _schemaToWireOrNull(entry.value) == null) {
      return false;
    }
  }
  return true;
}

NormalizedSchemaInput? _schemaToWireOrNull(Object? value) {
  try {
    return _schemaToWire(value);
  } catch (_) {
    return null;
  }
}

/// Port of upstream `hashSchemaInput`.
///
/// Missing schema hashes the literal text `undefined`, matching the producer.
String hashSchemaInput(Object? schema) {
  if (schema == null) return digestInterruptJson('undefined');
  final normalized = _schemaToWire(schema);
  final identity = normalized?.jsonSchema ??
      <String, dynamic>{'standardValidator': 'unserialized'};
  return digestInterruptJson(canonicalInterruptJson(identity));
}

/// Port of upstream `hashInterruptDefinitionSchema`.
///
/// Definition schemas are expected to expose a JSON Schema converter; raw
/// maps are accepted as the already-converted shape. `$schema` is excluded.
String hashInterruptDefinitionSchema(Object? schema) {
  final wire = _schemaToWire(schema, stripSchemaKeyword: true);
  if (wire == null || wire.jsonSchema == null) {
    throw ArgumentError(
      'Interrupt schema must be a Standard Schema with a JSON Schema '
      'converter.',
    );
  }
  return digestInterruptJson(canonicalInterruptJson(wire.jsonSchema));
}
