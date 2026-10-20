import 'dart:convert';
import 'dart:io';

import 'package:tanstack_ai_dart/src/processing/message_converters.dart';
import 'package:test/test.dart';

dynamic wire(dynamic value) {
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Map) return value.map((key, item) => MapEntry(key, wire(item)));
  if (value is List) return value.map(wire).toList();
  return value;
}

void main() {
  test('generated message identities remain unique in a tight loop', () {
    final ids = List.generate(10000, (_) => generateMessageId());
    expect(ids.toSet().length, ids.length);
  });
  final fixture = jsonDecode(File(
    'test/processing/fixtures/message_converters.json',
  ).readAsStringSync()) as Map;
  group('official JS message converter reference', () {
    for (final (index, entry) in (fixture['uiToModel'] as List).indexed) {
      test('UI to model $index', () {
        expect(
            wire(uiMessageToModelMessages(
              Map<String, dynamic>.from(entry['input'] as Map),
            )),
            entry['expected']);
      });
    }
    for (final (index, entry) in (fixture['modelToUI'] as List).indexed) {
      test('model to UI $index', () {
        final input = Map<String, dynamic>.from(entry['input'] as Map);
        expect(wire(modelMessageToUIMessage(input, input['id'] as String)),
            entry['expected']);
      });
    }
  });
}
