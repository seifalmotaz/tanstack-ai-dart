import 'dart:convert';
import 'dart:io';

import 'package:tanstack_ai_dart/processing.dart';
import 'package:test/test.dart';

void main() {
  final fixtures = jsonDecode(
    File('test/processing/fixtures/partial_json.json').readAsStringSync(),
  ) as List;
  group('partial-json reference prefix parity', () {
    for (final (index, fixture) in fixtures.indexed) {
      test('prefix $index: ${jsonEncode(fixture['input'])}', () {
        expect(
            parsePartialJSON(fixture['input'] as String), fixture['expected']);
      });
    }
  });
}
