import 'dart:convert';

import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';

/// Runnable only when an endpoint is available.
///
/// This makes a real HTTP request. Do not run it as part of automated checks.
Future<void> main() async {
  final transport = SseChatTransport(
    'http://localhost:3000/ai/chat',
    headers: () => {'Content-Type': 'application/json'},
    onUnauthorized: () async {
      // Refresh credentials here.
    },
  );

  final turns = <AssistantTurn>[AssistantTurn.user('Hello')];
  final body = assistantChatBody(null, turns);

  try {
    await for (final event in transport.stream(body)) {
      print(jsonEncode(event));
    }
  } on ChatTransportException catch (e) {
    print('Chat failed (${e.status} ${e.code}): ${e.message}');
  }
}
