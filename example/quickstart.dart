import 'dart:io';

import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';

/// Run with your endpoint: dart run example/quickstart.dart URL [MESSAGE]
/// The endpoint must implement the pinned TanStack AI streaming protocol.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stdout.writeln('Usage: dart run example/quickstart.dart URL [MESSAGE]');
    return;
  }
  final client = ChatClient(
    connection: fetchServerSentEvents(args.first),
    threadId: 'dart-example',
  );
  final subscription = client.states.listen((snapshot) {
    if (snapshot.messages.isNotEmpty) {
      stdout.writeln(snapshot.messages.last.answer);
    }
  });
  try {
    await client.attach();
    await client.sendText(args.length > 1 ? args[1] : 'Hello');
    if (client.error != null) {
      stderr.writeln(client.error);
      exitCode = 1;
    }
  } finally {
    await subscription.cancel();
    await client.dispose();
  }
}
