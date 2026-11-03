import 'package:tanstack_ai_dart/src/processing/message_converters.dart';
import 'package:tanstack_ai_dart/src/processing/processor.dart';
import 'package:test/test.dart';

void main() {
  group('activity sidecars', () {
    test('peels inbound activity messages with their transcript index', () {
      final records = peelInboundActivities([
        {
          'id': 'u1',
          'role': 'user',
          'parts': [
            {'type': 'text', 'content': 'hi'},
          ],
        },
        {
          'id': 'a1',
          'role': 'activity',
          'activityType': 'SEARCH',
          'content': {'query': 'cash'},
          'subagentRunId': 'sub-1',
          'metadata': {'source': 'wire'},
        },
        {
          'id': 'm1',
          'role': 'assistant',
          'parts': [
            {'type': 'text', 'content': 'done'},
          ],
        },
      ]);
      expect(records, hasLength(1));
      expect(records.single, {
        'id': 'a1',
        'activityType': 'SEARCH',
        'content': {'query': 'cash'},
        'index': 1,
        'subagentRunId': 'sub-1',
        'metadata': {'source': 'wire'},
      });
    });

    test('interleaves activity records at their stored indexes', () {
      final rows = interleaveActivityRecords(
        [
          {
            'id': 'm1',
            'role': 'user',
            'parts': [
              {'type': 'text', 'content': 'one'},
            ],
          },
          {
            'id': 'm2',
            'role': 'assistant',
            'parts': [
              {'type': 'text', 'content': 'two'},
            ],
          },
        ],
        [
          {
            'id': 'act-2',
            'activityType': 'PLAN',
            'content': {'step': 2},
            'index': 2,
          },
          {
            'id': 'act-0',
            'activityType': 'SEARCH',
            'content': {'step': 0},
            'index': 0,
          },
        ],
      );
      expect(rows.map((row) => row['id']).toList(),
          ['act-0', 'm1', 'act-2', 'm2']);
      final activity = rows.first;
      expect(activity['role'], 'activity');
      expect(activity['parts'], [
        {
          'type': 'activity',
          'activityType': 'SEARCH',
          'content': {'step': 0},
        },
      ]);
    });

    test('record round-trips through its UI message shape', () {
      final record = <String, dynamic>{
        'id': 'act-1',
        'activityType': 'SEARCH',
        'content': {
          'query': 'cash',
          'nested': {'deep': true},
        },
        'index': 3,
        'metadata': {'source': 'persist'},
      };
      final ui = activityRecordToUIMessage(record);
      expect(ui['id'], 'act-1');
      expect(ui['role'], 'activity');
      final peeled = peelInboundActivities([ui]);
      expect(peeled.single['activityType'], 'SEARCH');
      expect(peeled.single['content'], record['content']);
      expect(peeled.single['metadata'], record['metadata']);
    });
  });

  group('recording provider and model', () {
    test('startRecording stores provider and model when supplied', () {
      final processor = StreamProcessor();
      processor.startRecording(model: 'gpt-5.5', provider: 'openai');
      final recording = processor.getRecording()!;
      expect(recording.model, 'gpt-5.5');
      expect(recording.provider, 'openai');
      expect(recording.version, '1.0');
    });

    test('recording serializes model and provider with chunks', () {
      final processor = StreamProcessor();
      processor.startRecording(model: 'claude', provider: 'anthropic');
      processor.processChunk(<String, dynamic>{
        'type': 'TEXT_MESSAGE_CONTENT',
        'messageId': 'msg-1',
        'delta': 'hi',
      });
      final json = processor.getRecording()!.toJson();
      expect(json['model'], 'claude');
      expect(json['provider'], 'anthropic');
      expect((json['chunks'] as List), hasLength(1));
    });
  });
}
