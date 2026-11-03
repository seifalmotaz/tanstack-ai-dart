import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

void main() {
  group('legacy mobile tool output presence', () {
    test('constructors and assignment distinguish explicit null from absent',
        () {
      final missing = AssistantPart.tool(id: 'missing', name: 'lookup');
      final completed =
          AssistantPart.tool(id: 'completed', name: 'lookup', output: null);
      expect(missing.toJson().containsKey('output'), isFalse);
      expect(completed.toJson().containsKey('output'), isTrue);
      missing.output = null;
      expect(missing.toJson().containsKey('output'), isTrue);
    });
    test('completed null output survives UI wire serialization', () {
      final part = AssistantPart.fromJson({
        'type': 'tool-call',
        'id': 'tc',
        'name': 'lookup',
        'arguments': '{}',
        'state': 'complete',
        'output': null,
      });
      final turn = AssistantTurn(id: 'a', role: 'assistant', parts: [part]);
      final encoded =
          (assistantWireMessages([turn]).single['parts'] as List).single as Map;
      expect(encoded.containsKey('output'), isTrue);
      expect(encoded['output'], isNull);
    });
    test('an approval without output keeps that field absent', () {
      final part = AssistantPart.fromJson({
        'type': 'tool-call',
        'id': 'tc',
        'name': 'lookup',
        'arguments': '{}',
        'state': 'approval-requested',
        'approval': {'id': 'approval', 'needsApproval': true},
      });
      final turn = AssistantTurn(id: 'a', role: 'assistant', parts: [part]);
      final encoded =
          (assistantWireMessages([turn]).single['parts'] as List).single as Map;
      expect(encoded.containsKey('output'), isFalse);
    });
  });
}
