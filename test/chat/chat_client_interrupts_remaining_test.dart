// Upstream reference: packages/ai-client/tests/chat-client-interrupts.test.ts
// (ChatClient native interrupt cases and V2 fallback cases).
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/connections.dart' as conn;
import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

import 'support.dart';

final StandardSchema lookupOutput = StandardSchema((value) async =>
    value is Map && value['accountId'] is String
        ? SchemaValidationResult.success(value)
        : SchemaValidationResult.failure(
            const <SchemaIssue>[SchemaIssue('accountId is required')]));

Map<String, dynamic> genericDescriptor(String id) => <String, dynamic>{
      'id': id,
      'reason': 'confirmation',
      'metadata': <String, dynamic>{
        'tanstack:interruptBinding': <String, dynamic>{
          'v': 1,
          'kind': 'generic',
          'interruptId': id,
          'interruptedRunId': 'run-1',
          'generation': 0,
          'responseSchemaHash': 'none',
        },
      },
    };

Map<String, dynamic> descriptor(
  Map<String, dynamic> binding, {
  Map<String, dynamic> overrides = const <String, dynamic>{},
}) =>
    <String, dynamic>{
      'id': binding['interruptId'],
      'reason': binding['kind'] == 'tool-approval'
          ? 'tool_call'
          : binding['kind'] == 'client-tool-execution'
              ? 'tanstack:client_tool_execution'
              : 'confirmation',
      if (binding['kind'] != 'generic') 'toolCallId': binding['toolCallId'],
      'metadata': <String, dynamic>{'tanstack:interruptBinding': binding},
      ...overrides,
    };

conn.ConnectionAdapter emptyConnection() => conn.ConnectionAdapter(
      connect: (messages, {data, signal, runContext}) =>
          const Stream<Map<String, dynamic>>.empty(),
    );

void main() {
  group('ChatClient native interrupts', () {
    test('publishes the shared immutable interrupt state callback', () {
      ChatInterruptState? lastState;
      String? lastSource;
      final client = ChatClient(
        connection: emptyConnection(),
        initialResumeSnapshot: ChatResumeSnapshot(
          resumeState:
              const ChatResumeState(threadId: 'thread-1', runId: 'run-1'),
          pendingInterrupts: <Map<String, dynamic>>[
            genericDescriptor('generic-1'),
          ],
        ),
        onInterruptStateChange: (state, source) {
          lastState = state;
          lastSource = source;
        },
      );

      expect(lastSource, 'hydrate');
      expect(lastState, same(client.getInterruptState()));
      expect(lastState!.interrupts, same(lastState!.pendingInterrupts));
      client.dispose();
    });

    test('reports source hydrate when a client-tool interrupt is restored', () {
      String? lastSource;
      final outputSchemaHash = hashSchemaInput(lookupOutput);
      final client = ChatClient(
        connection: emptyConnection(),
        tools: <ClientTool>[
          ClientTool(name: 'lookup', outputSchema: lookupOutput)
        ],
        initialResumeSnapshot: ChatResumeSnapshot(
          resumeState:
              const ChatResumeState(threadId: 'thread-1', runId: 'run-1'),
          pendingInterrupts: <Map<String, dynamic>>[
            descriptor(<String, dynamic>{
              'v': 1,
              'kind': 'client-tool-execution',
              'interruptId': 'client-1',
              'interruptedRunId': 'run-1',
              'generation': 0,
              'toolName': 'lookup',
              'toolCallId': 'call-2',
              'outputSchemaHash': outputSchemaHash,
              'responseSchemaHash': outputSchemaHash,
            }),
          ],
        ),
        onInterruptStateChange: (_, source) => lastSource = source,
      );

      expect(client.getInterrupts(), isEmpty);
      expect(lastSource, 'hydrate');
      client.dispose();
    });

    test(
        'reports source hydrate when a first-party generic interrupt is restored',
        () {
      String? lastSource;
      const responseSchema = <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'answer': <String, dynamic>{'type': 'number'},
        },
        'required': <String>['answer'],
      };
      final hash = hashInterruptDefinitionSchema(responseSchema);
      final binding = <String, dynamic>{
        'v': 1,
        'kind': 'generic',
        'interruptId': 'generic_review_one',
        'interruptedRunId': 'run-1',
        'generation': 0,
        'definitionId': 'approval',
        'key': 'one',
        'batchIndex': 0,
        'responseSchemaHash': hash,
      };
      final client = ChatClient(
        connection: emptyConnection(),
        initialResumeSnapshot: ChatResumeSnapshot(
          resumeState:
              const ChatResumeState(threadId: 'thread-1', runId: 'run-1'),
          pendingInterrupts: <Map<String, dynamic>>[descriptor(binding)],
        ),
        interrupts: <ChatInterruptDefinition>[
          ChatInterruptDefinition(
              id: 'approval', responseSchema: responseSchema),
        ],
        onInterruptStateChange: (_, source) => lastSource = source,
      );

      expect(client.getInterrupts().single.kind, 'generic');
      expect(lastSource, 'hydrate');
      client.dispose();
    });

    for (final timing in <String>[
      'resolve-after',
      'reject-after',
      'resolve-before',
      'add-result-after',
    ]) {
      test('does not continue when $timing after Stop', () async {
        final toolCompleter = Completer<Map<String, dynamic>>();
        final lookup = ClientTool(
          name: 'lookup',
          outputSchema: lookupOutput,
          execute: (input, context) => toolCompleter.future,
        );
        final responseSchema = <String, dynamic>{};
        final outputSchemaHash = hashSchemaInput(lookupOutput);
        final responseSchemaHash =
            digestInterruptJson(canonicalInterruptJson(responseSchema));
        final contexts = <conn.RunAgentInputContext?>[];
        final release = Completer<void>();
        var calls = 0;
        final connection = conn.ConnectionAdapter(
          connect: (messages, {data, signal, runContext}) async* {
            contexts.add(runContext);
            calls++;
            final runId = runContext?.runId ?? 'run-$calls';
            yield <String, dynamic>{
              'type': 'RUN_STARTED',
              'runId': runId,
              'threadId': 'thread-1',
            };
            if (calls == 1) {
              yield <String, dynamic>{
                'type': 'TOOL_CALL_START',
                'toolCallId': 'call-1',
                'toolCallName': 'lookup',
              };
              yield <String, dynamic>{
                'type': 'TOOL_CALL_ARGS',
                'toolCallId': 'call-1',
                'delta': '{}',
              };
              yield <String, dynamic>{
                'type': 'CUSTOM',
                'name': 'tool-input-available',
                'value': <String, dynamic>{
                  'toolCallId': 'call-1',
                  'toolName': 'lookup',
                  'input': <String, dynamic>{},
                },
              };
              yield <String, dynamic>{
                'type': 'RUN_FINISHED',
                'runId': runId,
                'threadId': 'thread-1',
                'outcome': <String, dynamic>{
                  'type': 'interrupt',
                  'interrupts': <Map<String, dynamic>>[
                    descriptor(<String, dynamic>{
                      'v': 1,
                      'kind': 'client-tool-execution',
                      'interruptId': 'client-1',
                      'interruptedRunId': runId,
                      'generation': 0,
                      'toolName': 'lookup',
                      'toolCallId': 'call-1',
                      'outputSchemaHash': outputSchemaHash,
                      'responseSchemaHash': responseSchemaHash,
                    }, overrides: <String, dynamic>{
                      'responseSchema': responseSchema,
                    }),
                  ],
                },
              };
              await release.future;
              return;
            }
            yield <String, dynamic>{
              'type': 'TEXT_MESSAGE_START',
              'messageId': 'msg-$calls',
              'role': 'assistant',
            };
            yield <String, dynamic>{
              'type': 'TEXT_MESSAGE_CONTENT',
              'messageId': 'msg-$calls',
              'delta': 'ok',
            };
            yield <String, dynamic>{
              'type': 'TEXT_MESSAGE_END',
              'messageId': 'msg-$calls',
            };
            yield <String, dynamic>{
              'type': 'RUN_FINISHED',
              'runId': runId,
              'threadId': 'thread-1',
              'outcome': <String, dynamic>{'type': 'success'},
            };
          },
        );
        final client = ChatClient(
          connection: connection,
          threadId: 'thread-1',
          tools: <ClientTool>[lookup],
        );

        final send = client.sendMessage('start');
        await waitFor(() => client.getResumeState() != null);
        if (timing == 'resolve-before') {
          toolCompleter.complete(<String, dynamic>{'accountId': 'account-1'});
          await waitFor(() => client.getInterruptState().resuming);
        }
        final messagesAtStop =
            client.getMessages().map((m) => m.toRow()).toList();
        await client.stop();
        if (timing == 'resolve-after' || timing == 'add-result-after') {
          if (!toolCompleter.isCompleted) {
            toolCompleter.complete(<String, dynamic>{'accountId': 'account-1'});
          }
        } else if (timing == 'reject-after') {
          if (!toolCompleter.isCompleted) {
            toolCompleter.completeError(StateError('tool failed'));
          }
        }
        release.complete();
        await send;
        await settle();

        if (timing == 'add-result-after') {
          await client.addToolResult(
            toolCallId: 'call-1',
            tool: 'lookup',
            output: <String, dynamic>{'accountId': 'late-result'},
          );
          await settle();
        }

        expect(contexts, hasLength(1));
        expect(client.getMessages().map((m) => m.toRow()), messagesAtStop);
        expect(client.getResumeState(), isNull);
        expect(client.getInterrupts(), isEmpty);
        expect(client.getInterruptState().interruptErrors, isEmpty);
        expect(client.getInterruptState().resuming, isFalse);

        await client.sendMessage('later');
        expect(contexts, hasLength(2));
        expect(contexts[1]?.parentRunId, isNull);
        expect(contexts[1]?.resume, isNull);
        client.dispose();
      });
    }

    test(
        'owns one immutable interrupt state and resumes with a fresh child run',
        () async {
      final contexts = <conn.RunAgentInputContext?>[];
      final sentMessages = <List<conn.WireMessage>>[];
      final binding = <String, dynamic>{
        'v': 1,
        'kind': 'generic',
        'interruptId': 'generic-1',
        'interruptedRunId': 'placeholder',
        'generation': 4,
        'responseSchemaHash': 'none',
      };
      var call = 0;
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          contexts.add(runContext);
          sentMessages.add(messages);
          call++;
          final runId = runContext?.runId ?? 'run-$call';
          yield <String, dynamic>{
            'type': 'RUN_STARTED',
            'runId': runId,
            'threadId': 'thread-1',
          };
          if (call == 1) {
            binding['interruptedRunId'] = runId;
            yield <String, dynamic>{
              'type': 'RUN_FINISHED',
              'runId': runId,
              'threadId': 'thread-1',
              'outcome': <String, dynamic>{
                'type': 'interrupt',
                'interrupts': <Map<String, dynamic>>[descriptor(binding)],
              },
            };
            return;
          }
          yield <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': runId,
            'threadId': 'thread-1',
            'outcome': <String, dynamic>{'type': 'success'},
          };
        },
      );
      final sources = <String?>[];
      final client = ChatClient(
        connection: connection,
        threadId: 'thread-1',
        onInterruptStateChange: (_, source) => sources.add(source),
      );

      await client.sendMessage('start');
      expect(sources.last, 'live');
      final state = client.getInterruptState();
      expect(state.interrupts, same(state.pendingInterrupts));
      expect(client.getInterrupts(), same(state.interrupts));
      expect(client.getPendingInterrupts(), same(state.interrupts));
      state.interrupts.single.resolveInterrupt(<String, dynamic>{'answer': 42});

      await waitFor(() => contexts.length == 2);
      expect(contexts[1]?.threadId, 'thread-1');
      expect(contexts[1]?.parentRunId, contexts[0]?.runId);
      expect(contexts[1]?.resume, <Map<String, dynamic>>[
        <String, dynamic>{
          'interruptId': 'generic-1',
          'status': 'resolved',
          'payload': <String, dynamic>{'answer': 42},
        },
      ]);
      expect(contexts[1]?.runId, isNot(contexts[0]?.runId));
      expect(sentMessages[1], isNotEmpty);
      expect(sentMessages[1], sentMessages[0]);
      client.dispose();
    });

    test('sends first-party continuation on resume metadata', () async {
      const responseSchema = <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'answer': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['answer'],
      };
      final responseHash = hashInterruptDefinitionSchema(responseSchema);
      final contexts = <conn.RunAgentInputContext?>[];
      var call = 0;
      final connection = conn.ConnectionAdapter(
        connect: (messages, {data, signal, runContext}) async* {
          contexts.add(runContext);
          call++;
          final runId = runContext?.runId ?? 'run-$call';
          yield <String, dynamic>{
            'type': 'RUN_STARTED',
            'runId': runId,
            'threadId': 'thread-1',
          };
          if (call == 1) {
            yield <String, dynamic>{
              'type': 'RUN_FINISHED',
              'runId': runId,
              'threadId': 'thread-1',
              'outcome': <String, dynamic>{
                'type': 'interrupt',
                'interrupts': <Map<String, dynamic>>[
                  descriptor(<String, dynamic>{
                    'v': 1,
                    'kind': 'generic',
                    'interruptId': 'generic-1',
                    'interruptedRunId': runId,
                    'generation': 0,
                    'definitionId': 'approval',
                    'key': 'one',
                    'batchIndex': 0,
                    'responseSchemaHash': responseHash,
                  }, overrides: <String, dynamic>{
                    'responseSchema': responseSchema,
                  }),
                ],
              },
            };
            return;
          }
          yield <String, dynamic>{
            'type': 'RUN_FINISHED',
            'runId': runId,
            'threadId': 'thread-1',
            'outcome': <String, dynamic>{'type': 'success'},
          };
        },
      );
      final client = ChatClient(
        connection: connection,
        threadId: 'thread-1',
        interrupts: <ChatInterruptDefinition>[
          ChatInterruptDefinition(
              id: 'approval', responseSchema: responseSchema),
        ],
      );

      await client.sendMessage('start');
      final item = client.getInterrupts().single;
      item.resolveInterrupt(<String, dynamic>{'answer': 'yes'});
      await waitFor(() => contexts.length == 2);
      final resume = contexts[1]?.resume?.single;
      expect(resume?['metadata'], isNotNull);
      client.dispose();
    });

    test(
        'does not auto-send after a completed tool when a generic interrupt is pending',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x');
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r'},
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
        <String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': 'r',
          'threadId': 'thread-1',
          'outcome': <String, dynamic>{
            'type': 'interrupt',
            'interrupts': <Map<String, dynamic>>[genericDescriptor('i1')],
          },
        },
      ]);
      await transport.close();
      await pump();
      expect(transport.bodies, hasLength(1));
      await client.stop();
    });

    test('does not auto-send after rejecting an afterTools generic interrupt',
        () async {
      final transport = FakeChatTransport();
      final client = ChatClient(transport: transport);
      await client.sendText('x');
      await emitAll(transport, <Map<String, dynamic>>[
        <String, dynamic>{'type': 'RUN_STARTED', 'runId': 'r'},
        <String, dynamic>{
          'type': 'RUN_FINISHED',
          'runId': 'r',
          'threadId': 'thread-1',
          'outcome': <String, dynamic>{
            'type': 'interrupt',
            'interrupts': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'i1',
                'reason': 'choose',
                'metadata': <String, dynamic>{'kind': 'generic'},
              },
            ],
          },
        },
      ]);
      await transport.close();
      await pump();
      client.getInterrupts().single.resolveInterrupt(<String, dynamic>{
        'reject': true,
      });
      await pump(8);
      expect(client.getInterrupts(), isNotEmpty);
      expect(transport.bodies, hasLength(1));
      await client.stop();
    });

    test(
        'resumes a hydrated ephemeral batch with full history in a fresh child run',
        () async {
      final contexts = <conn.RunAgentInputContext?>[];
      final sentMessages = <List<Map<String, dynamic>>>[];
      final client = ChatClient(
          threadId: 'thread-1',
          connection: conn.ConnectionAdapter(
            connect: (messages, {data, signal, runContext}) async* {
              contexts.add(runContext);
              sentMessages.add(messages);
              final runId = runContext!.runId;
              yield {
                'type': 'RUN_FINISHED',
                'runId': runId,
                'threadId': 'thread-1',
                'outcome': contexts.length == 1
                    ? {
                        'type': 'interrupt',
                        'interrupts': [
                          for (final id in ['first', 'second'])
                            descriptor({
                              'v': 1,
                              'kind': 'generic',
                              'interruptId': id,
                              'interruptedRunId': runId,
                              'generation': 1,
                              'responseSchemaHash': 'none'
                            })
                        ]
                      }
                    : {'type': 'success'}
              };
            },
          ));
      addTearDown(client.dispose);
      await client.sendMessage('start');
      final visited = <String>[];
      client.resolveInterrupts((ChatInterrupt item) {
        visited.add(item.id);
        item.cancel();
        return null;
      });
      await waitFor(() => contexts.length == 2);
      expect(visited, ['first', 'second']);
      expect(contexts[1]!.threadId, 'thread-1');
      expect(contexts[1]!.parentRunId, contexts[0]!.runId);
      expect(contexts[1]!.runId, isNot(contexts[0]!.runId));
      expect(contexts[1]!.resume, [
        {'interruptId': 'first', 'status': 'cancelled'},
        {'interruptId': 'second', 'status': 'cancelled'}
      ]);
      expect(sentMessages[1], isNotEmpty);
      expect(sentMessages[1], sentMessages[0]);
    });

    test('hydrates V2 fallback descriptors when recovery is unavailable', () {
      final client = ChatClient(
        connection: emptyConnection(),
        initialResumeSnapshot: ChatResumeSnapshot.fromJson(<String, dynamic>{
          'resumeState': <String, dynamic>{
            'threadId': 'thread-1',
            'runId': 'run-1',
          },
          'pendingInterrupts': <Map<String, dynamic>>[
            genericDescriptor('fallback'),
          ],
          'interruptState': <String, dynamic>{
            'recoveryState': <String, dynamic>{
              'schemaVersion': 1,
              'state': 'pending',
              'threadId': 'other-thread',
              'interruptedRunId': 'run-1',
              'generation': 99,
              'pendingInterrupts': <dynamic>[],
            },
            'drafts': <dynamic>[],
          },
        }),
      );

      expect(client.getResumeState()?.threadId, 'thread-1');
      expect(client.getResumeState()?.runId, 'run-1');
      expect(
          client.getInterrupts().map((item) => item.id), <String>['fallback']);
      expect(client.getInterruptState().interruptErrors, isEmpty);
      client.dispose();
    });

    for (final entry in <String, Map<String, dynamic>>{
      'null recovery state': <String, dynamic>{
        'recoveryState': null,
        'drafts': <dynamic>[],
      },
      'array recovery state': <String, dynamic>{
        'recoveryState': <dynamic>[],
        'drafts': <dynamic>[],
      },
      'invalid drafts': <String, dynamic>{
        'recoveryState': <String, dynamic>{
          'schemaVersion': 1,
          'state': 'pending',
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
          'pendingInterrupts': <dynamic>[],
        },
        'drafts': <String, dynamic>{'interruptId': 'not-an-array'},
      },
    }.entries) {
      test(
          'hydrates fallback descriptors for malformed V2 ${entry.key} without losing resume state',
          () {
        late ChatClient client;
        expect(() {
          client = ChatClient(
            connection: emptyConnection(),
            initialResumeSnapshot:
                ChatResumeSnapshot.fromJson(<String, dynamic>{
              'resumeState': <String, dynamic>{
                'threadId': 'thread-1',
                'runId': 'run-1',
              },
              'pendingInterrupts': <Map<String, dynamic>>[
                genericDescriptor('fallback'),
              ],
              'interruptState': entry.value,
            }),
          );
        }, returnsNormally);
        expect(client.getResumeState()?.threadId, 'thread-1');
        expect(client.getResumeState()?.runId, 'run-1');
        expect(client.getInterrupts().map((item) => item.id),
            <String>['fallback']);
        expect(client.getInterruptState().interruptErrors, isEmpty);
        client.dispose();
      });
    }
  });
}

Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
