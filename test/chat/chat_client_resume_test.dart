// Upstream reference: packages/ai-client/tests/chat-client-resume.test.ts
import 'package:tanstack_ai_dart/chat.dart';
import 'package:test/test.dart';

import 'support.dart';

List<Map<String, dynamic>> interruptRun({
  String runId = 'run-1',
  String threadId = 'thread-1',
  String id = 'interrupt-1',
  String reason = 'approval_required',
  Map<String, dynamic> metadata = const <String, dynamic>{
    'kind': 'approval',
    'toolName': 'confirm',
    'input': <String, dynamic>{},
  },
  String? toolCallId,
}) =>
    <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'RUN_STARTED',
        'runId': runId,
        'threadId': threadId,
      },
      <String, dynamic>{
        'type': 'TEXT_MESSAGE_CONTENT',
        'messageId': 'm1',
        'delta': 'a',
      },
      <String, dynamic>{
        'type': 'RUN_FINISHED',
        'runId': runId,
        'threadId': threadId,
        'outcome': <String, dynamic>{
          'type': 'interrupt',
          'interrupts': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': id,
              'reason': reason,
              if (toolCallId != null) 'toolCallId': toolCallId,
              'metadata': metadata,
            },
          ],
        },
      },
    ];

Future<ChatClient> interruptedClient(
  FakeChatTransport transport, {
  List<Map<String, dynamic>>? chunks,
}) async {
  final client = ChatClient(
    transport: transport,
    options: const ChatClientOptions(threadId: 'thread-1'),
  );
  await client.sendText('hi');
  await emitAll(transport, chunks ?? interruptRun());
  await transport.close();
  await pump();
  return client;
}

void main() {
  group('ChatClient resume', () {
    test('tracks the run/thread of an interrupted run', () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(transport);
      final state = client.getResumeState();
      expect(state, isNotNull);
      expect(state!.threadId, 'thread-1');
      expect(state.runId, 'run-1');
      expect(client.getPendingInterrupts().single.id, 'interrupt-1');
    });

    test('clears resume state once the run finishes', () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        options: const ChatClientOptions(threadId: 'thread-1'),
      );
      await client.sendText('hi');
      await emitAll(transport, textChunks('a'));
      await transport.close();
      await pump();
      expect(client.getResumeState(), isNull);
    });

    test(
        'reports the current run id for an ordinary run and clears it on finish',
        () async {
      final seen = <String?>[];
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        onRunIdChange: seen.add,
      );
      expect(client.getCurrentRunId(), isNull);
      await client.sendText('hi');
      expect(client.getCurrentRunId(), isNotNull);
      await emitAll(transport, textChunks('a'));
      await transport.close();
      await pump();
      expect(client.getCurrentRunId(), isNull);
      expect(seen.length, greaterThanOrEqualTo(2));
      expect(seen.last, isNull);
    });

    test(
        'preserves resume state and tracks pending interrupts on interrupt terminal',
        () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(transport);
      expect(client.getResumeState()!.threadId, 'thread-1');
      expect(client.getPendingInterrupts(), hasLength(1));
    });

    test(
        'resumeInterrupts sends AG-UI resume entries with the interrupted run context',
        () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(transport);
      final state = client.getResumeState()!;
      final resumeItems = <Map<String, dynamic>>[
        <String, dynamic>{
          'interruptId': 'interrupt-1',
          'status': 'resolved',
          'payload': <String, dynamic>{'approved': true},
        },
      ];
      await client.resumeInterrupts(resumeItems);
      final body = transport.bodies[1];
      expect(body['threadId'], state.threadId);
      expect(body['parentRunId'], state.runId);
      expect(body['resume'], resumeItems);
      expect(body['runId'], isNot(state.runId));

      await emitAll(
        transport,
        <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': 'run-2',
            'threadId': 'thread-1',
            'outcome': <String, dynamic>{'type': 'success'},
          },
        ],
      );
      await transport.closeAt(1);
      await pump();
      expect(client.getPendingInterrupts(), isEmpty);
      expect(client.getResumeState(), isNull);
    });

    test('clears interrupts when a resumed provider run has a different run id',
        () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(transport);
      await client.resumeInterruptsUnsafe(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'interruptId': 'interrupt-1',
            'status': 'resolved',
          },
        ],
        threadId: 'thread-1',
        runId: 'run-1',
      );
      await emitAll(
        transport,
        <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'RUN_STARTED',
            'runId': 'provider-run',
            'threadId': 'thread-1',
          },
          <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': 'provider-run',
            'threadId': 'thread-1',
            'outcome': <String, dynamic>{'type': 'success'},
          },
        ],
      );
      await transport.closeAt(1);
      await pump();
      expect(client.getResumeState(), isNull);
    });

    test('blocks normal input while interrupts are pending', () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(transport);
      await expectLater(client.sendText('next'), throwsStateError);
    });

    test('clear removes resume state and pending interrupts', () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(transport);
      await client.clear();
      expect(client.getResumeState(), isNull);
      expect(client.getPendingInterrupts(), isEmpty);
    });

    test('addToolApprovalResponse sends a compatibility resume item', () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(
        transport,
        chunks: interruptRun(toolCallId: 'tool-1'),
      );
      await client.addToolApprovalResponse(id: 'interrupt-1', approved: true);
      await waitFor(() => transport.bodies.length == 2);
      final resume = transport.bodies[1]['resume'] as List;
      expect((resume.single as Map)['interruptId'], 'interrupt-1');
      expect(
        ((resume.single as Map)['payload'] as Map)['approved'],
        isTrue,
      );
      await client.stop();
    });

    test(
        'addToolApprovalResponse waits for all pending approval interrupts before resuming',
        () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(
        transport,
        chunks: <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'RUN_STARTED',
            'runId': 'run-1',
            'threadId': 'thread-1',
          },
          <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': 'run-1',
            'threadId': 'thread-1',
            'outcome': <String, dynamic>{
              'type': 'interrupt',
              'interrupts': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'i1',
                  'reason': 'approval_required',
                  'toolCallId': 't1',
                  'metadata': <String, dynamic>{
                    'kind': 'approval',
                    'toolName': 'a',
                    'input': <String, dynamic>{},
                  },
                },
                <String, dynamic>{
                  'id': 'i2',
                  'reason': 'approval_required',
                  'toolCallId': 't2',
                  'metadata': <String, dynamic>{
                    'kind': 'approval',
                    'toolName': 'b',
                    'input': <String, dynamic>{},
                  },
                },
              ],
            },
          },
        ],
      );
      await client.addToolApprovalResponse(id: 'i1', approved: true);
      await pump(20);
      expect(transport.bodies, hasLength(1));
      await client.addToolApprovalResponse(id: 'i2', approved: false);
      await waitFor(() => transport.bodies.length == 2);
      expect((transport.bodies[1]['resume'] as List), hasLength(2));
      await client.stop();
    });

    test('restores pending interrupts from an initial resume snapshot',
        () async {
      final client = ChatClient(
        transport: FakeChatTransport(),
        options: const ChatClientOptions(
          initialResume: ChatResumeState(threadId: 't', runId: 'r'),
          initialInterrupts: ChatHydrationInterrupts(
            runId: 'r',
            pending: <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'i1',
                'reason': 'approval_required',
                'metadata': <String, dynamic>{
                  'kind': 'approval',
                  'toolName': 'confirm',
                  'input': <String, dynamic>{},
                },
              },
            ],
          ),
        ),
      );
      expect(client.getResumeState()!.runId, 'r');
      expect(client.getPendingInterrupts().single.id, 'i1');
    });

    test('resolves a generic interrupt and auto-resumes with entries',
        () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(transport);
      final interrupt = client.getInterrupts().single;
      interrupt.resolveInterrupt(<String, dynamic>{'answer': 'continue'});
      await waitFor(() => transport.bodies.length == 2);
      expect(transport.bodies[1]['parentRunId'], 'run-1');
      final resume = transport.bodies[1]['resume'] as List;
      expect((resume.single as Map)['payload'], <String, dynamic>{
        'answer': 'continue',
      });
      await client.stop();
    });

    test('correlates a synthesized resume finish to the client request run',
        () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(transport);
      await client.resumeInterrupts(<Map<String, dynamic>>[
        <String, dynamic>{'interruptId': 'interrupt-1', 'status': 'resolved'},
      ]);
      final requestRun = transport.bodies[1]['runId'];
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': requestRun,
          'threadId': 'thread-1',
          'outcome': <String, dynamic>{'type': 'success'},
        },
      ]);
      await transport.closeAt(1);
      await pump();
      expect(client.getResumeState(), isNull);
    });

    test('correlates a synthesized resume error to the client request run',
        () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(transport);
      await client.resumeInterrupts(<Map<String, dynamic>>[
        <String, dynamic>{'interruptId': 'interrupt-1', 'status': 'resolved'},
      ]);
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'RUN_ERROR',
          'message': 'resume failed',
        },
      ]);
      await transport.closeAt(1);
      await pump();
      expect(client.getError(), contains('resume failed'));
    });

    test('resumeInterrupts reconnects with the full current message history',
        () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(transport);
      await client.resumeInterrupts(<Map<String, dynamic>>[
        <String, dynamic>{'interruptId': 'interrupt-1', 'status': 'resolved'},
      ]);
      final ids = (transport.bodies[1]['messages'] as List)
          .map((row) => (row as Map)['id'])
          .toList();
      expect(ids, contains(client.getMessages().first.id));
      await client.stop();
    });

    test('clears resume state and pending interrupts on a runless RUN_ERROR',
        () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(transport);
      transport.emit(<String, dynamic>{
        'type': 'RUN_ERROR',
        'message': 'runless',
      });
      await pump();
      expect(client.getSessionGenerating(), isFalse);
      await client.stop();
      expect(client.getResumeState(), isNull);
      expect(client.getPendingInterrupts(), isEmpty);
    });

    test('keeps pending interrupts when an unrelated run finishes', () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(transport);
      transport.emit(<String, dynamic>{
        'type': 'RUN_FINISHED',
        'runId': 'unrelated',
        'threadId': 'thread-1',
        'outcome': <String, dynamic>{'type': 'success'},
      });
      await pump();
      expect(client.getPendingInterrupts(), hasLength(1));
      await client.stop();
    });

    test('keeps pending interrupts when an unrelated run starts and finishes',
        () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(transport);
      transport.emit(<String, dynamic>{
        'type': 'RUN_STARTED',
        'runId': 'unrelated',
        'threadId': 'thread-1',
      });
      transport.emit(<String, dynamic>{
        'type': 'RUN_FINISHED',
        'runId': 'unrelated',
        'threadId': 'thread-1',
        'outcome': <String, dynamic>{'type': 'success'},
      });
      await pump();
      expect(client.getPendingInterrupts(), hasLength(1));
      await client.stop();
    });

    test('keeps pending interrupts when an unrelated run errors', () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(transport);
      transport.emit(<String, dynamic>{
        'type': 'RUN_ERROR',
        'runId': 'unrelated',
        'message': 'boom',
      });
      await pump();
      expect(client.getPendingInterrupts(), hasLength(1));
      await client.stop();
    });

    test('addToolResult for pending client-tool input sends a resume item',
        () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(
        transport,
        chunks: interruptRun(
          reason: 'client_tool_input',
          metadata: <String, dynamic>{
            'kind': 'client_tool',
            'toolName': 'lookup',
            'input': <String, dynamic>{'id': 1},
          },
          toolCallId: 'tc1',
        ),
      );
      await client.addToolResult(
        toolCallId: 'tc1',
        tool: 'lookup',
        output: <String, dynamic>{'found': 1},
      );
      await waitFor(() => transport.bodies.length == 2);
      final resume = transport.bodies[1]['resume'] as List;
      expect((resume.single as Map)['interruptId'], 'interrupt-1');
      await client.stop();
    });

    test(
        'addToolResult waits for all pending client-tool interrupts before resuming',
        () async {
      final transport = FakeChatTransport();
      final client = await interruptedClient(
        transport,
        chunks: <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'RUN_STARTED',
            'runId': 'run-1',
            'threadId': 'thread-1',
          },
          <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': 'run-1',
            'threadId': 'thread-1',
            'outcome': <String, dynamic>{
              'type': 'interrupt',
              'interrupts': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'i1',
                  'reason': 'client_tool_input',
                  'toolCallId': 't1',
                  'metadata': <String, dynamic>{
                    'kind': 'client_tool',
                    'toolName': 'a',
                    'input': <String, dynamic>{},
                  },
                },
                <String, dynamic>{
                  'id': 'i2',
                  'reason': 'client_tool_input',
                  'toolCallId': 't2',
                  'metadata': <String, dynamic>{
                    'kind': 'client_tool',
                    'toolName': 'b',
                    'input': <String, dynamic>{},
                  },
                },
              ],
            },
          },
        ],
      );
      await client.addToolResult(toolCallId: 't1', output: 1);
      await pump(20);
      expect(transport.bodies, hasLength(1));
      await client.addToolResult(toolCallId: 't2', output: 2);
      await waitFor(() => transport.bodies.length == 2);
      expect((transport.bodies[1]['resume'] as List), hasLength(2));
      await client.stop();
    });

    test(
        'auto-executed client tool during parent stream defers resume until isLoading clears',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(
        transport: transport,
        tools: <ChatClientTool>[
          ChatClientTool(name: 'lookup', execute: (input, context) => 7),
        ],
      );
      await client.sendText('hi');
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r1'},
        <String, dynamic>{
          'type': 'TOOL_CALL_START',
          'toolCallId': 'tc',
          'toolCallName': 'lookup',
        },
        <String, dynamic>{
          'type': 'TOOL_CALL_END',
          'toolCallId': 'tc',
          'toolCallName': 'lookup',
          'input': <String, dynamic>{},
        },
      ]);
      await pump(8);
      expect(transport.bodies, hasLength(1));
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': 'r1',
          'outcome': <String, dynamic>{'type': 'success'},
        },
      ]);
      await transport.close();
      await waitFor(() => transport.bodies.length == 2);
      await client.stop();
    });
  });
}
