@TestOn('vm')
library;

import 'package:tanstack_ai_dart/src/chat/part_view.dart';
import 'package:tanstack_ai_dart/src/protocol.dart';
import 'package:test/test.dart';

String describe(ChatPart part) => switch (part) {
      ChatTextPart() => 'text',
      ChatThinkingPart() => 'thinking',
      ChatToolCallPart() => 'toolCall',
      ChatToolResultPart() => 'toolResult',
      ChatActivityPart() => 'activity',
      ChatStructuredPart() => 'structured',
      ChatSubagentPart() => 'subagent',
      ChatMediaPart() => 'media',
      ChatUnknownPart() => 'unknown',
    };

void main() {
  group('ChatPart variants', () {
    test('text, thinking and tool views keep typed fields', () {
      final text = AssistantPart.text('hello').chatPart;
      final thinking = AssistantPart.fromJson(<String, dynamic>{
        'type': 'thinking',
        'id': 'thought-1',
        'content': 'checking',
        'signature': 'sig-1',
        'redacted': true,
      }).chatPart;
      final call = AssistantPart.fromJson(<String, dynamic>{
        'type': 'tool-call',
        'id': 'call-1',
        'name': 'getWeather',
        'arguments': '{"city":"Paris"}',
        'input': <String, dynamic>{'city': 'Paris'},
        'output': <String, dynamic>{'temperature': 21},
        'state': 'complete',
        'approval': <String, dynamic>{'id': 'a-1', 'needsApproval': false},
      }).chatPart;

      expect(text, isA<ChatTextPart>());
      expect((text as ChatTextPart).content, 'hello');

      expect(thinking, isA<ChatThinkingPart>());
      final thinkingView = thinking as ChatThinkingPart;
      expect(thinkingView.id, 'thought-1');
      expect(thinkingView.content, 'checking');
      expect(thinkingView.signature, 'sig-1');
      expect(thinkingView.redacted, isTrue);

      expect(call, isA<ChatToolCallPart>());
      final callView = call as ChatToolCallPart;
      expect(callView.id, 'call-1');
      expect(callView.name, 'getWeather');
      expect(callView.arguments, '{"city":"Paris"}');
      expect(callView.input, <String, dynamic>{'city': 'Paris'});
      expect(callView.hasInput, isTrue);
      expect(callView.output, <String, dynamic>{'temperature': 21});
      expect(callView.hasOutput, isTrue);
      expect(callView.state, 'complete');
      expect(callView.approval, <String, dynamic>{
        'id': 'a-1',
        'needsApproval': false,
      });
    });

    test('tool-result and activity views keep presence and outcomes', () {
      final result = AssistantPart.fromJson(<String, dynamic>{
        'type': 'tool-result',
        'id': 'result-1',
        'name': 'getWeather',
        'toolCallId': 'call-1',
        'content': null,
        'state': 'complete',
        'outcome': 'denied',
        'error': 'blocked',
      }).chatPart;
      final activity = AssistantPart(
        type: 'activity',
        id: 'activity-1',
        activityType: 'SEARCH',
        activityContent: <String, dynamic>{'query': 'pizza'},
      ).chatPart;

      expect(result, isA<ChatToolResultPart>());
      final resultView = result as ChatToolResultPart;
      expect(resultView.id, 'result-1');
      expect(resultView.name, 'getWeather');
      expect(resultView.toolCallId, 'call-1');
      expect(resultView.hasOutput, isTrue);
      expect(resultView.output, isNull);
      expect(resultView.state, 'complete');
      expect(resultView.outcome, 'denied');
      expect(resultView.error, 'blocked');

      expect(activity, isA<ChatActivityPart>());
      final activityView = activity as ChatActivityPart;
      expect(activityView.id, 'activity-1');
      expect(activityView.activityType, 'SEARCH');
      expect(activityView.content, <String, dynamic>{'query': 'pizza'});
    });

    test('structured and subagent views keep their payloads', () {
      final structured = AssistantPart.fromJson(<String, dynamic>{
        'type': 'structured-output',
        'status': 'complete',
        'raw': '{"title":"Pizza"}',
        'data': <String, dynamic>{'title': 'Pizza'},
        'partial': <String, dynamic>{'title': 'Piz'},
        'reasoning': 'merged',
        'errorMessage': '',
      }).chatPart;
      final subagent = AssistantPart.fromJson(<String, dynamic>{
        'type': 'subagent',
        'subagent': <String, dynamic>{'id': 'agent-1', 'status': 'done'},
      }).chatPart;

      expect(structured, isA<ChatStructuredPart>());
      final structuredView = structured as ChatStructuredPart;
      expect(structuredView.status, 'complete');
      expect(structuredView.raw, '{"title":"Pizza"}');
      expect(structuredView.data, <String, dynamic>{'title': 'Pizza'});
      expect(structuredView.hasData, isTrue);
      expect(structuredView.partial, <String, dynamic>{'title': 'Piz'});
      expect(structuredView.hasPartial, isTrue);
      expect(structuredView.reasoning, 'merged');
      expect(structuredView.hasReasoning, isTrue);

      expect(subagent, isA<ChatSubagentPart>());
      final subagentView = subagent as ChatSubagentPart;
      expect(subagentView.id, 'agent-1');
      expect(subagentView.subagent, <String, dynamic>{
        'id': 'agent-1',
        'status': 'done',
      });
    });

    test('every media type is represented without losing fields', () {
      for (final type in <String>['image', 'audio', 'video', 'document']) {
        final wire = <String, dynamic>{
          'type': type,
          'id': '$type-1',
          'source': <String, dynamic>{
            'type': 'url',
            'value': 'https://example.test/$type',
            'nested': <String, dynamic>{'mimeType': 'application/octet-stream'},
          },
          'metadata': <String, dynamic>{'label': type},
          'futureField': <String, dynamic>{'kept': true},
        };
        final view = AssistantPart.fromJson(wire).chatPart;

        expect(view, isA<ChatMediaPart>(), reason: type);
        final media = view as ChatMediaPart;
        expect(media.type, type);
        expect(media.mediaType, type);
        expect(media.id, '$type-1');
        expect(media.source, wire['source']);
        expect(media.wire['metadata'], wire['metadata']);
        expect(media.wire['futureField'], wire['futureField']);
        expect(describe(media), 'media');
      }
    });

    test('unknown types and exotic fields survive as unknown views', () {
      final wire = <String, dynamic>{
        'type': 'ui-resource',
        'id': 'resource-1',
        'resource': <String, dynamic>{'uri': 'ui://card'},
        'futureField': <String, dynamic>{
          'items': <Object?>[1, 2, 3],
        },
      };
      final view = AssistantPart.fromJson(wire).chatPart;

      expect(view, isA<ChatUnknownPart>());
      expect(view.type, 'ui-resource');
      expect(view.wire['resource'], wire['resource']);
      expect(view.wire['futureField'], wire['futureField']);
      expect(describe(view), 'unknown');
    });

    test('switching over every variant is exhaustive', () {
      final parts = <ChatPart>[
        AssistantPart.text('hello').chatPart,
        AssistantPart.thinking(id: 't', content: 'think').chatPart,
        AssistantPart.tool(id: 'c', name: 'tool').chatPart,
        AssistantPart(type: 'tool-result', toolCallId: 'c').chatPart,
        AssistantPart(type: 'activity').chatPart,
        AssistantPart(type: 'structured-output').chatPart,
        AssistantPart(type: 'subagent').chatPart,
        AssistantPart(type: 'image').chatPart,
        AssistantPart(type: 'future-part').chatPart,
      ];

      expect(
        parts.map(describe),
        <String>[
          'text',
          'thinking',
          'toolCall',
          'toolResult',
          'activity',
          'structured',
          'subagent',
          'media',
          'unknown',
        ],
      );
    });
  });

  group('ChatPart snapshots', () {
    test('do not alias the mutable source part or its containers', () {
      final input = <String, dynamic>{
        'nested': <Object?>[1, 2],
      };
      final metadata = <String, dynamic>{
        'tags': <Object?>['a'],
      };
      final source = AssistantPart.tool(
        id: 'call-1',
        name: 'getWeather',
        input: input,
        metadata: metadata,
      );
      final view = source.chatPart as ChatToolCallPart;

      (input['nested'] as List<Object?>).add(3);
      (metadata['tags'] as List<Object?>).add('b');
      source.content = 'mutated';
      source.input = <String, dynamic>{
        'nested': <Object?>[9]
      };

      expect(view.input, <String, dynamic>{
        'nested': <Object?>[1, 2],
      });
      expect(view.wire['metadata'], <String, dynamic>{
        'tags': <Object?>['a'],
      });
      expect(view.wire['content'], isNull);
    });

    test('expose deeply read-only wire JSON and payloads', () {
      final view = AssistantPart.fromJson(<String, dynamic>{
        'type': 'tool-call',
        'id': 'call-1',
        'name': 'getWeather',
        'input': <String, dynamic>{
          'nested': <String, dynamic>{
            'items': <Object?>[1, 2],
          },
        },
        'output': <Object?>[],
      }).chatPart as ChatToolCallPart;

      expect(() => view.wire['new'] = true, throwsUnsupportedError);
      final input = view.input as Map<String, dynamic>;
      expect(() => input['new'] = true, throwsUnsupportedError);
      final nested = input['nested'] as Map<String, dynamic>;
      expect(() => nested['new'] = true, throwsUnsupportedError);
      expect(() => (nested['items'] as List<Object?>).add(3),
          throwsUnsupportedError);
      expect(
          () => (view.output as List<Object?>).add(3), throwsUnsupportedError);
    });

    test('turn views are immutable and independent per part', () {
      final turn = AssistantTurn(
        id: 'turn-1',
        role: 'assistant',
        parts: <AssistantPart>[
          AssistantPart.text('hello'),
          AssistantPart(type: 'future-part'),
        ],
      );
      final views = turn.chatParts;

      expect(views.map(describe), <String>['text', 'unknown']);
      expect(() => views.add(AssistantPart.text('x').chatPart),
          throwsUnsupportedError);

      turn.parts[0].content = 'changed';
      expect((views.first as ChatTextPart).content, 'hello');
    });
  });
}
