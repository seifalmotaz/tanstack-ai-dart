// Upstream reference: packages/ai-client/src/run-ownership.ts
import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';

void main() {
  group('run ownership', () {
    test('ownsRun requires the current token and no cancellation', () {
      final a = ChatRunToken();
      final b = ChatRunToken();
      expect(ownsRun(a, a), isTrue);
      expect(ownsRun(b, a), isFalse);
      a.cancel();
      expect(ownsRun(a, a), isFalse);
    });

    test('owns treats a missing controller as owned', () {
      final a = ChatRunToken();
      expect(owns(a, null), isTrue);
      expect(owns(null, a), isFalse);
    });

    test('whileOwned stops when a step cancels or replaces the run', () {
      var current = ChatRunToken();
      final steps = <String>[];
      final ok = whileOwned(
        () => current,
        current,
        <void Function()>[
          () => steps.add('one'),
          () => current.cancel(),
          () => steps.add('three'),
        ],
      );
      expect(ok, isFalse);
      expect(steps, <String>['one']);
    });

    test('whileOwned returns true when ownership survives every step', () {
      final token = ChatRunToken();
      final steps = <String>[];
      final ok = whileOwned(
        () => token,
        token,
        <void Function()>[
          () => steps.add('one'),
          () => steps.add('two'),
        ],
      );
      expect(ok, isTrue);
      expect(steps, <String>['one', 'two']);
    });
  });
}
