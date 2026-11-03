import 'dart:convert';

import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';
import 'package:test/test.dart';

class _CaptureTransport implements ChatTransport {
  Map<String, dynamic>? sent;
  @override
  Stream<Map<String, dynamic>> stream(Map<String, dynamic> body) {
    sent = body;
    return Stream.fromIterable([
      {'type': 'RUN_FINISHED', 'runId': 'run', 'threadId': 'thread'},
    ]);
  }
}

void main() {
  // Upstream: chat-client-context.test.ts, client-local context boundary.
  test('client-local tool context never enters an outbound request', () async {
    final transport = _CaptureTransport();
    final client = ChatClient(
      transport: transport,
      context: {
        'localUserId': 'local',
        'secretToken': 'test-local-only-marker'
      },
    );
    addTearDown(client.stop);
    await client.sendText('hello');
    expect(transport.sent, isNotNull);
    expect(
        jsonEncode(transport.sent), isNot(contains('test-local-only-marker')));
    expect(transport.sent!['context'], isEmpty);
  });
}
