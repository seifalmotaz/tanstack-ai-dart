import 'dart:convert';
import 'dart:io';

import 'package:tanstack_ai_dart/src/processing/agui_wire.dart';
import 'package:test/test.dart';

void main() {
  final fixture = jsonDecode(File(
    'test/processing/fixtures/message_converters.json',
  ).readAsStringSync()) as Map;
  group('official JS outbound wire reference', () {
    for (final (index, entry) in (fixture['uiToWire'] as List).indexed) {
      test('UI to AG-UI wire $index', () {
        expect(
            uiMessagesToWire([
              for (final message in entry['input'] as List)
                Map<String, dynamic>.from(message as Map),
            ]),
            entry['expected']);
      });
    }
    for (final (index, entry) in (fixture['snapshotWire'] as List).indexed) {
      test('snapshot to AG-UI wire $index', () {
        expect(
            uiMessagesToWire([
              for (final message in entry['input'] as List)
                Map<String, dynamic>.from(message as Map),
            ], includeActivity: true, includeSnapshotStructuredOutput: true),
            entry['expected']);
      });
    }
  });
}
