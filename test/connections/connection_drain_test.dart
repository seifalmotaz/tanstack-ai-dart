// Ported from packages/ai-client/tests/connection-drain.test.ts
// Test names intentionally mirror the upstream file.
import 'dart:async';

import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

void main() {
  test('waits for a slow subscriber before resolving send', () async {
    final releaseGate = Completer<void>();
    final controller = CancellationController();
    final adapter = normalizeConnectionAdapter(
      stream((messages, data, signal) async* {
        yield {
          'type': 'RUN_FINISHED',
          'threadId': 'thread',
          'runId': 'run',
          'timestamp': 0,
        };
      }),
    );
    var processed = false;
    final consuming = () async {
      await for (final _ in adapter.subscribe(signal: controller.signal)) {
        await releaseGate.future;
        processed = true;
      }
    }();
    var settled = false;
    final sending = adapter.send([]).then((_) => settled = true);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(settled, isFalse);

    releaseGate.complete();
    await sending;
    expect(processed, isTrue);

    controller.cancel();
    await consuming;
  });

  test('does not wait for a subscriber that has exited', () async {
    final adapter = normalizeConnectionAdapter(
      stream((messages, data, signal) async* {
        yield {
          'type': 'RUN_FINISHED',
          'threadId': 'thread',
          'runId': 'run',
          'timestamp': 0,
        };
      }),
    );
    final consuming = () async {
      await for (final _ in adapter.subscribe()) {
        break;
      }
    }();
    await adapter.send([]);
    await consuming;
  });
}
