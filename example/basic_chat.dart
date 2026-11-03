import 'package:tanstack_ai_dart/tanstack_ai_dart.dart';

Future<void> runChat(String endpoint) async {
  final client = ChatClient(
    connection: fetchServerSentEvents(endpoint),
    threadId: 'conversation-123',
  );
  final subscription = client.states.listen((snapshot) {
    for (final message in snapshot.messages) {
      print('${message.role}: ${message.answer}');
    }
  });

  try {
    await client.attach();
    await client.sendText('Hello');
    if (client.error != null) {
      throw StateError(client.error!);
    }
  } finally {
    await subscription.cancel();
    await client.dispose();
  }
}
