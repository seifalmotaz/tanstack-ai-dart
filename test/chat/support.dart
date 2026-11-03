import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';

class FakeChatTransport implements ChatTransport {
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
  final List<StreamController<Map<String, dynamic>>> controllers =
      <StreamController<Map<String, dynamic>>>[];

  @override
  Stream<Map<String, dynamic>> stream(Map<String, dynamic> body) {
    bodies.add(body);
    final controller = StreamController<Map<String, dynamic>>();
    controllers.add(controller);
    return controller.stream;
  }

  void emit(Map<String, dynamic> event) {
    if (controllers.isEmpty || controllers.last.isClosed) return;
    controllers.last.add(event);
  }

  void emitError(Object error, [StackTrace? stack]) {
    controllers.last.addError(error, stack);
  }

  Future<void> close() async {
    if (controllers.isEmpty || controllers.last.isClosed) return;
    await controllers.last.close();
  }

  Future<void> closeAt(int index) async {
    await controllers[index].close();
  }
}

Future<void> pump([int turns = 4]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> waitFor(bool Function() condition, {int tries = 200}) async {
  for (var i = 0; i < tries; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('condition was not met');
}

AssistantTurn userMessage(String id, String text) => AssistantTurn(
      id: id,
      role: 'user',
      parts: <AssistantPart>[AssistantPart.text(text)],
    );

AssistantTurn assistantMessage(String id, List<AssistantPart> parts) =>
    AssistantTurn(id: id, role: 'assistant', parts: parts);

Map<String, dynamic> textRun(List<String> deltas, {String runId = 'run-1'}) =>
    <String, dynamic>{};

List<Map<String, dynamic>> textChunks(
  String text, {
  String messageId = 'msg-1',
  String runId = 'run-1',
}) {
  final out = <Map<String, dynamic>>[
    <String, dynamic>{
      'type': 'RUN_STARTED',
      'runId': runId,
      'threadId': 'thread-1',
      'timestamp': 1,
    },
    <String, dynamic>{
      'type': 'TEXT_MESSAGE_START',
      'messageId': messageId,
      'role': 'assistant',
      'timestamp': 1,
    },
  ];
  for (final char in text.split('')) {
    out.add(<String, dynamic>{
      'type': 'TEXT_MESSAGE_CONTENT',
      'messageId': messageId,
      'delta': char,
      'timestamp': 1,
    });
  }
  out.add(<String, dynamic>{
    'type': 'TEXT_MESSAGE_END',
    'messageId': messageId,
    'timestamp': 1,
  });
  out.add(<String, dynamic>{
    'type': 'RUN_FINISHED',
    'runId': runId,
    'threadId': 'thread-1',
    'timestamp': 1,
    'outcome': <String, dynamic>{'type': 'success'},
    'metadata': <String, dynamic>{
      'tanstack': <String, dynamic>{'finishReason': 'stop'},
    },
  });
  return out;
}

Future<void> emitAll(
  FakeChatTransport transport,
  List<Map<String, dynamic>> chunks,
) async {
  for (final chunk in chunks) {
    transport.emit(chunk);
    await Future<void>.delayed(Duration.zero);
  }
}
