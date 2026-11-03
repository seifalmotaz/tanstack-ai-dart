library;

// ignore_for_file: deprecated_member_use_from_same_package

import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';

void main() {
  group('ClientTool approval schema', () {
    test('is stored on the tool itself', () {
      const schema = <String, Object?>{'type': 'object'};
      final tool = ClientTool<Object?, Object?>(
        name: 'approve_me',
        approvalSchema: schema,
      );

      expect(tool.approvalSchema, same(schema));
      expect(clientToolApprovalSchema(tool), same(schema));
    });

    test('defaults to null and does not leak between tools', () {
      const schema = <String, Object?>{'type': 'object'};
      final approved = ClientTool<Object?, Object?>(
        name: 'approved',
        approvalSchema: schema,
      );
      final plain = ClientTool<Object?, Object?>(name: 'plain');

      expect(plain.approvalSchema, isNull);
      expect(clientToolApprovalSchema(plain), isNull);
      expect(approved.approvalSchema, same(schema));
    });

    test('legacy ChatClientTool keeps its approvalSchema field', () {
      const schema = <String, Object?>{'approve': <String, Object?>{}};
      const tool = ChatClientTool(name: 'legacy', approvalSchema: schema);

      expect(tool, isA<ClientTool<dynamic, dynamic>>());
      expect(clientToolApprovalSchema(tool), same(schema));
    });
  });

  group('schema helpers', () {
    test('raw JSON maps and opaque values become raw schemas', () {
      const raw = <String, Object?>{'type': 'string'};
      final fromMap = asToolSchema(raw);
      final fromValue = asToolSchema(42);

      expect(fromMap, isA<RawJsonSchema>());
      expect(fromMap!.jsonSchema, same(raw));
      expect(fromValue, isA<RawJsonSchema>());
      expect(fromValue!.jsonSchema, 42);
      expect(convertSchemaToJsonSchema(fromMap), same(raw));
    });

    test('standard schema delegates validation and keeps its JSON view',
        () async {
      final schema = StandardSchema(
        (value) => value == 'ok'
            ? const SchemaValidationResult.success('ok')
            : const SchemaValidationResult.failure(
                [SchemaIssue('expected ok')],
              ),
        schema: const <String, Object?>{'type': 'string'},
      );

      expect(asToolSchema(schema), same(schema));
      expect(convertSchemaToJsonSchema(schema), const <String, Object?>{
        'type': 'string',
      });
      expect((await validateWithSchema(schema, 'ok')).success, isTrue);
      expect((await validateWithSchema(schema, 'no')).success, isFalse);
      expect((await validateWithSchema(null, 'anything')).success, isTrue);
    });
  });

  group('clientTools compatibility helper', () {
    test('returns an independent list with the same elements', () {
      final tool = ClientTool<Object?, Object?>(name: 'one');
      final tools = clientTools<ClientTool>(<ClientTool>[tool]);

      expect(tools, isNot(same(<ClientTool>[tool])));
      expect(tools, hasLength(1));
      expect(tools.single, same(tool));
    });
  });
}
