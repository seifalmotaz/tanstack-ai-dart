// Upstream reference: packages/ai-client/src/chat-client.ts (run lineage) and
// tests/chat-client-interrupt-lineage-replay.test.ts.
import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';

Map<String, dynamic> pause(String runId) => <String, dynamic>{
      'id': 'i-$runId',
      'reason': 'approval_required',
      'metadata': <String, dynamic>{
        'kind': 'approval',
        'toolName': 'confirm',
        'input': <String, dynamic>{},
      },
    };

ChatHydrationInterrupts hydration(String runId) => ChatHydrationInterrupts(
      runId: runId,
      pending: <Map<String, dynamic>>[pause(runId)],
    );

void main() {
  group('InterruptLineage', () {
    test('suppresses a parent pause replayed after its child answered', () {
      final manager = InterruptManager();

      manager.trackRunSettled('run-B');
      expect(
        manager.trackRunStarted('run-B', parentRunId: 'run-A'),
        isFalse,
        reason: 'a late RUN_STARTED for a settled child is replay, not live',
      );
      manager.hydrate(hydration('run-A'));

      expect(manager.getInterrupts(), isEmpty);
    });

    test('clears a visible pause when a completed child gains its parent link',
        () {
      final manager = InterruptManager();

      expect(manager.trackRunStarted('run-A'), isTrue);
      manager.hydrate(hydration('run-A'));
      expect(manager.getInterrupts(), hasLength(1));

      manager.trackRunSettled('run-B');
      expect(
        manager.trackRunStarted('run-B', parentRunId: 'run-A'),
        isFalse,
      );

      expect(manager.getInterrupts(), isEmpty);
    });

    test('preserves an unrelated pause when another child gains a parent link',
        () {
      final manager = InterruptManager();

      expect(manager.trackRunStarted('run-D'), isTrue);
      manager.hydrate(hydration('run-D'));
      expect(manager.getInterrupts(), hasLength(1));

      manager.trackRunSettled('run-B');
      expect(
        manager.trackRunStarted('run-B', parentRunId: 'run-A'),
        isFalse,
      );

      expect(manager.getInterrupts(), hasLength(1));
      expect(manager.getInterrupts().single.interruptedRunId, 'run-D');
    });

    test('propagates completion through late transitive parent links', () {
      final manager = InterruptManager();

      manager.trackRunSettled('run-C');
      expect(
        manager.trackRunStarted('run-C', parentRunId: 'run-B'),
        isFalse,
      );
      manager.hydrate(hydration('run-A'));
      expect(manager.getInterrupts(), hasLength(1));

      expect(
        manager.trackRunStarted('run-B', parentRunId: 'run-A'),
        isFalse,
      );
      expect(manager.getInterrupts(), isEmpty);
    });

    test('stays closed across a second replay, even after an explicit reset',
        () {
      final manager = InterruptManager();

      manager.trackRunStarted('run-A');
      manager.hydrate(hydration('run-A'));
      manager.trackRunStarted('run-B', parentRunId: 'run-A');
      manager.trackRunSettled('run-B');
      expect(manager.getInterrupts(), isEmpty);

      manager.reset();
      expect(
        manager.trackRunStarted('run-A'),
        isFalse,
        reason: 'lineage outlives interrupt state so replay stays idempotent',
      );
      manager.hydrate(hydration('run-A'));
      expect(manager.getInterrupts(), isEmpty);
    });

    test('stale hydration does not replace an unrelated pending pause', () {
      final manager = InterruptManager();

      manager.trackRunSettled('run-A');
      manager.hydrate(hydration('run-D'));
      manager.hydrate(hydration('run-A'));

      expect(manager.getInterrupts(), hasLength(1));
      expect(manager.getInterrupts().single.interruptedRunId, 'run-D');
    });

    test('settling an unrelated run leaves the pause pending', () {
      final manager = InterruptManager();

      manager.trackRunStarted('run-A');
      manager.hydrate(hydration('run-A'));
      manager.trackRunStarted('run-C');
      manager.trackRunSettled('run-C');

      expect(manager.getInterrupts(), hasLength(1));
      expect(manager.getInterrupts().single.interruptedRunId, 'run-A');
    });

    test('marks known ancestors answered and stops on a cyclic parent chain',
        () {
      final lineage = InterruptLineage()
        ..recordStart('a', parentRunId: 'b')
        ..recordStart('b', parentRunId: 'a')
        ..markAnswered('a');

      expect(lineage.isAnswered('a'), isTrue);
      expect(lineage.isAnswered('b'), isTrue);
    });
  });

  group('foreign interrupt semantics', () {
    test('keeps an unbound foreign pause visible and unresolvable', () {
      final manager = InterruptManager();
      manager.hydrate(
        const ChatHydrationInterrupts(
          runId: 'run-foreign',
          pending: <Map<String, dynamic>>[
            <String, dynamic>{'id': 'foreign', 'reason': 'foreign_pause'},
          ],
        ),
      );

      manager.trackRunSettled('run-other');

      final interrupt = manager.getInterrupts().single;
      expect(interrupt.kind, 'unbound');
      expect(interrupt.canResolve, isFalse);
      expect(manager.resolveInterrupt('foreign', <String, dynamic>{}), isFalse);
    });
  });
}
