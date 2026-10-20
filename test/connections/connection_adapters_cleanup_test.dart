// Ported from
// packages/ai-client/tests/connection-adapters-cleanup.test.ts
// Test names mirror the upstream file.
//
// Platform distinction: upstream distinguishes "cancel" from "drain" because a
// WHATWG ReadableStream reports `cancel` only on early teardown. Dart's
// StreamController always invokes onCancel when the subscription ends, so these
// tests assert that cleanup happens (the response stream is released) and that
// the parse error wins over a failing cleanup.
import 'dart:async';

import 'package:tanstack_ai_dart/connections.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  for (final entry in <({
    String name,
    ConnectionAdapter Function(Object, FetchConnectionOptions) create,
    String Function(String) frame,
  })>[
    (
      name: 'SSE',
      create: fetchServerSentEvents,
      frame: (data) => 'data: $data\n\n',
    ),
    (
      name: 'NDJSON',
      create: fetchHttpStream,
      frame: (data) => '$data\n',
    ),
  ]) {
    group('${entry.name} response cleanup', () {
      ({ControlledResponse body, ConnectionAdapter adapter}) connection(
        String data, {
        bool close = false,
        FutureOr<void> Function()? onCancel,
      }) {
        final body = ControlledResponse(onCancel);
        final client = FakeHttpClient((_) async => body.response);
        body.write(entry.frame(data));
        if (close) {
          unawaited(body.close());
        }
        return (
          body: body,
          adapter: entry.create(
            '/chat',
            FetchConnectionOptions(client: client),
          ),
        );
      }

      test('cancels the response when JSON parsing fails', () async {
        final setup = connection('{invalid json}');
        final iterator = StreamIterator(setup.adapter.connect!([]));

        await expectLater(
          iterator.moveNext(),
          throwsA(isA<FormatException>()),
        );
        await iterator.cancel();
        expect(setup.body.cancelled, isTrue);
      });

      for (final pendingCancellation in [false, true]) {
        test(
            'cancels the response on early return '
            '(pending cancellation: $pendingCancellation)', () async {
          final setup = connection(
            '{"type":"RUN_STARTED","threadId":"thread","runId":"run"}',
            onCancel:
                pendingCancellation ? () => Completer<void>().future : null,
          );
          await for (final received in setup.adapter.connect!([])) {
            expect(received['type'], 'RUN_STARTED');
            break;
          }
          expect(setup.body.cancelled, isTrue);
        });
      }

      for (final behavior in ['throws', 'rejects', 'never settles']) {
        test('preserves a parse error when cancellation $behavior', () async {
          final setup = connection(
            '{invalid json}',
            onCancel: () {
              if (behavior == 'throws') throw StateError('cleanup failed');
              if (behavior == 'rejects') {
                return Future<void>.error(StateError('cleanup failed'));
              }
              return Completer<void>().future;
            },
          );
          final iterator = StreamIterator(setup.adapter.connect!([]));

          await expectLater(
            iterator.moveNext(),
            throwsA(isA<FormatException>()),
          );
          await iterator.cancel();
          expect(setup.body.cancelled, isTrue);
        });
      }

      test('drains a normally closed response without canceling its source',
          () async {
        final setup = connection(
          '{"type":"RUN_STARTED","threadId":"thread","runId":"run"}',
          close: true,
        );
        final chunks = await collect(setup.adapter.connect!([]));
        expect(chunks, [
          {'type': 'RUN_STARTED', 'threadId': 'thread', 'runId': 'run'},
        ]);
      });
    });
  }

  test('cancels an SSE response after the DONE sentinel', () async {
    final body = ControlledResponse();
    final client = FakeHttpClient((_) async => body.response);
    body.write('data: [DONE]\n\n');
    final adapter = fetchServerSentEvents(
      '/chat',
      FetchConnectionOptions(client: client),
    );

    final chunks = await collect(adapter.connect!([]));

    expect(chunks, hasLength(1));
    expect(chunks.single['type'], 'RUN_FINISHED');
    expect(body.cancelled, isTrue);
  });
}
