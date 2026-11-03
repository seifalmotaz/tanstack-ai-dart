// Upstream reference: packages/ai-client/tests/chat-client-interrupts.test.ts
// (the InterruptManager describes). Assertions mirror the pinned source.
import 'dart:async';

import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

const Map<String, dynamic> transferInput = <String, dynamic>{
  'type': 'object',
  'properties': <String, dynamic>{
    'cents': <String, dynamic>{'type': 'number'},
  },
  'required': <String>['cents'],
  'additionalProperties': false,
};

const Map<String, dynamic> transferOutput = <String, dynamic>{
  'type': 'object',
  'properties': <String, dynamic>{
    'receipt': <String, dynamic>{'type': 'string'},
  },
  'required': <String>['receipt'],
  'additionalProperties': false,
};

const Map<String, dynamic> transferApprove = <String, dynamic>{
  'type': 'object',
  'properties': <String, dynamic>{
    'note': <String, dynamic>{'type': 'string'},
  },
  'required': <String>['note'],
  'additionalProperties': false,
};

const Map<String, dynamic> transferReject = <String, dynamic>{
  'type': 'object',
  'properties': <String, dynamic>{
    'reason': <String, dynamic>{'type': 'string'},
  },
  'required': <String>['reason'],
  'additionalProperties': false,
};

final StandardSchema lookupOutput = StandardSchema((value) async =>
    _accountOutput(value)
        ? SchemaValidationResult.success(value)
        : SchemaValidationResult.failure(
            const <SchemaIssue>[SchemaIssue('accountId is required')]));

bool _accountOutput(Object? value) =>
    value is Map &&
    value['accountId'] is String &&
    (value['accountId'] as String).isNotEmpty;

final Map<String, dynamic> transferApproval = <String, dynamic>{
  'approve': transferApprove,
  'reject': transferReject,
};

final ClientTool transfer = ClientTool(
  name: 'transfer',
  needsApproval: true,
  inputSchema: transferInput,
  outputSchema: transferOutput,
  approvalSchema: transferApproval,
);

final ClientTool lookup = ClientTool(
  name: 'lookup',
  outputSchema: lookupOutput,
);

final List<ClientTool> tools = <ClientTool>[transfer, lookup];

Map<String, dynamic> descriptor(
  Map<String, dynamic> binding, {
  Map<String, dynamic> overrides = const <String, dynamic>{},
}) {
  final kind = '${binding['kind']}';
  return <String, dynamic>{
    'id': binding['interruptId'],
    'reason': kind == 'tool-approval'
        ? 'tool_call'
        : kind == 'client-tool-execution'
            ? 'tanstack:client_tool_execution'
            : 'confirmation',
    if (kind != 'generic') 'toolCallId': binding['toolCallId'],
    'metadata': <String, dynamic>{'tanstack:interruptBinding': binding},
    ...overrides,
  };
}

Map<String, dynamic> genericDescriptor(String id) =>
    descriptor(<String, dynamic>{
      'v': 1,
      'kind': 'generic',
      'interruptId': id,
      'interruptedRunId': 'run-1',
      'generation': 1,
      'responseSchemaHash': 'none',
    });

class ManagerFixture {
  final List<InterruptManagerSubmission> submissions =
      <InterruptManagerSubmission>[];
  final List<Completer<void>> pending = <Completer<void>>[];
  late final InterruptManager manager;

  ManagerFixture({bool manualSubmit = false}) {
    manager = InterruptManager(
      tools: tools,
      submitSubmission: (submission) {
        submissions.add(submission);
        if (!manualSubmit) return Future<void>.value();
        final completer = Completer<void>();
        pending.add(completer);
        return completer.future;
      },
    );
  }

  InterruptManager get value => manager;
}

void main() {
  group('InterruptManager foreign-interrupt handling', () {
    test(
        'surfaces an interrupt with no binding as unbound rather than resolvable generic',
        () {
      final manager = InterruptManager(tools: tools);
      manager.hydrate(const ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'workflow-approval-1',
            'reason': 'approval_requested',
            'message': 'Approve the deployment?',
            'metadata': <String, dynamic>{
              'acme:workflowApproval': <String, dynamic>{'stepId': 'deploy'},
            },
          },
        ],
      ));

      final item = manager.getInterrupts().single;
      expect(item.kind, 'unbound');
      expect(item.canResolve, isFalse);
      expect(item.onResolveInterrupt, isNull);
      expect(item.message, 'Approve the deployment?');
    });

    test('rejects a binding written at an unknown protocol version', () {
      final manager = InterruptManager(tools: tools);
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'future-1',
            'reason': 'confirmation',
            'metadata': <String, dynamic>{
              'tanstack:interruptBinding': <String, dynamic>{
                'v': 2,
                'kind': 'generic',
                'interruptId': 'future-1',
                'interruptedRunId': 'run-1',
                'generation': 1,
                'responseSchemaHash': 'none',
              },
            },
          },
        ],
      ));

      final item = manager.getInterrupts().single;
      expect(item.kind, 'unbound');
      expect(item.canResolve, isFalse);
    });

    test(
        'keeps a raw generic binding resolvable when run id and schema hash match',
        () {
      const responseSchema = <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'confirmed': <String, dynamic>{'type': 'boolean'},
        },
        'required': <String>['confirmed'],
      };
      final manager = InterruptManager(tools: tools);
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-foreign-1',
        threadId: 'foreign-1',
        generation: 0,
        pending: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'ours',
            'reason': 'confirmation',
            'message': 'Confirm the shipment?',
            'responseSchema': responseSchema,
            'metadata': <String, dynamic>{
              'tanstack:interruptBinding': <String, dynamic>{
                'v': 1,
                'kind': 'generic',
                'interruptId': 'ours',
                'interruptedRunId': 'run-foreign-1',
                'generation': 0,
                'responseSchemaHash':
                    digestInterruptJson(canonicalInterruptJson(responseSchema)),
              },
            },
          },
          <String, dynamic>{
            'id': 'theirs',
            'reason': 'approval_requested',
            'message': 'Approve the deployment?',
            'metadata': <String, dynamic>{
              'acme:workflowApproval': <String, dynamic>{'stepId': 'deploy'},
            },
          },
        ],
      ));

      final ours = manager.getInterrupts()[0];
      final theirs = manager.getInterrupts()[1];
      expect(ours.kind, 'generic');
      expect(ours.canResolve, isTrue);
      expect(ours.id, 'ours');
      expect(theirs.kind, 'unbound');
      expect(theirs.canResolve, isFalse);
      expect(theirs.id, 'theirs');
    });

    test('does not let an unbound interrupt block submission of the bound ones',
        () async {
      final submissions = <InterruptManagerSubmission>[];
      final manager = InterruptManager(
        tools: tools,
        submitSubmission: (submission) async => submissions.add(submission),
      );
      manager.hydrate(const ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'ours',
            'reason': 'confirmation',
            'metadata': <String, dynamic>{
              'tanstack:interruptBinding': <String, dynamic>{
                'v': 1,
                'kind': 'generic',
                'interruptId': 'ours',
                'interruptedRunId': 'run-1',
                'generation': 1,
                'responseSchemaHash': 'none',
              },
            },
          },
          <String, dynamic>{
            'id': 'theirs',
            'reason': 'approval_requested',
            'metadata': <String, dynamic>{},
          },
        ],
      ));

      manager.getInterrupts().first.resolveInterrupt(<String, dynamic>{
        'ok': true,
      });
      await settle();

      expect(submissions, hasLength(1));
      expect(
        submissions.single.resolutions.map((item) => item['interruptId']),
        <String>['ours'],
      );
    });
  });

  group('InterruptManager hydration', () {
    test(
        'hydrates correlated approval and client-tool bindings into typed snapshots',
        () {
      final approval = normalizeApprovalSchema(
        transferApproval,
        transferInput,
      );
      final approvalBinding = <String, dynamic>{
        'v': 1,
        'kind': 'tool-approval',
        'interruptId': 'approval-1',
        'interruptedRunId': 'run-1',
        'generation': 3,
        'toolName': 'transfer',
        'toolCallId': 'call-1',
        'originalArgs': <String, dynamic>{'cents': 100},
        'inputSchemaHash': hashSchemaInput(transferInput),
        'approvalSchemaHash': approval.approvalSchemaHash,
        'responseSchemaHash': approval.responseSchemaHash,
      };
      final outputSchemaHash = hashSchemaInput(lookupOutput);
      final clientBinding = <String, dynamic>{
        'v': 1,
        'kind': 'client-tool-execution',
        'interruptId': 'client-1',
        'interruptedRunId': 'run-1',
        'generation': 3,
        'toolName': 'lookup',
        'toolCallId': 'call-2',
        'outputSchemaHash': outputSchemaHash,
        'responseSchemaHash': outputSchemaHash,
      };
      final manager = InterruptManager(tools: tools);
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 3,
        pending: <Map<String, dynamic>>[
          descriptor(approvalBinding, overrides: <String, dynamic>{
            'responseSchema': approval.responseSchema,
          }),
          descriptor(clientBinding),
        ],
      ));

      final snapshot = manager.getInterrupts();
      expect(snapshot.map((item) => item.kind), <String>['tool-approval']);
      expect(snapshot.isNotEmpty, isTrue);
      expect(() => snapshot.add(snapshot.first), throwsUnsupportedError);
    });

    test(
        'hydrates a real core client-tool terminal with distinct schema identity hashes',
        () {
      final expectedOutputSchemaHash = hashSchemaInput(lookupOutput);
      final expectedResponseSchemaHash = digestInterruptJson(
        canonicalInterruptJson(
          convertSchemaToJsonSchema(lookupOutput.jsonSchema) ??
              <String, dynamic>{},
        ),
      );
      expect(expectedOutputSchemaHash, isNot(expectedResponseSchemaHash));

      final binding = <String, dynamic>{
        'v': 1,
        'kind': 'client-tool-execution',
        'interruptId': 'core-client',
        'interruptedRunId': 'core-run',
        'generation': 0,
        'toolName': 'lookup',
        'toolCallId': 'core-call',
        'outputSchemaHash': expectedOutputSchemaHash,
        'responseSchemaHash': expectedResponseSchemaHash,
      };
      final manager = InterruptManager(tools: tools);
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'core-run',
        threadId: 'core-thread',
        generation: 0,
        pending: <Map<String, dynamic>>[descriptor(binding)],
      ));
      expect(manager.getInterrupts(), isEmpty);

      final drift = Map<String, dynamic>.from(binding)
        ..['outputSchemaHash'] = 'sha256:configured-schema-drift';
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'core-run',
        threadId: 'core-thread',
        generation: 0,
        pending: <Map<String, dynamic>>[descriptor(drift)],
      ));
      expect(manager.getInterrupts().single.kind, 'generic');
    });

    test('keeps deprecated approval and client-tool reason aliases compatible',
        () {
      final approval = normalizeApprovalSchema(
        transferApproval,
        transferInput,
      );
      final approvalBinding = <String, dynamic>{
        'v': 1,
        'kind': 'tool-approval',
        'interruptId': 'approval-legacy',
        'interruptedRunId': 'run-legacy',
        'generation': 1,
        'toolName': 'transfer',
        'toolCallId': 'call-approval-legacy',
        'originalArgs': <String, dynamic>{'cents': 100},
        'inputSchemaHash': hashSchemaInput(transferInput),
        'approvalSchemaHash': approval.approvalSchemaHash,
        'responseSchemaHash': approval.responseSchemaHash,
      };
      final outputSchemaHash = hashSchemaInput(lookupOutput);
      final clientBinding = <String, dynamic>{
        'v': 1,
        'kind': 'client-tool-execution',
        'interruptId': 'client-legacy',
        'interruptedRunId': 'run-legacy',
        'generation': 1,
        'toolName': 'lookup',
        'toolCallId': 'call-client-legacy',
        'outputSchemaHash': outputSchemaHash,
        'responseSchemaHash': outputSchemaHash,
      };
      final manager = InterruptManager(tools: tools);
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-legacy',
        threadId: 'thread-legacy',
        generation: 1,
        pending: <Map<String, dynamic>>[
          descriptor(approvalBinding, overrides: <String, dynamic>{
            'reason': 'approval_required',
            'responseSchema': approval.responseSchema,
          }),
          descriptor(clientBinding,
              overrides: <String, dynamic>{'reason': 'client_tool_input'}),
        ],
      ));

      expect(manager.getInterrupts().map((item) => item.kind), <String>[
        'tool-approval',
      ]);
    });

    test(
        'degrades mismatched tool correlation to generic without trusting wire correlation',
        () {
      final outputSchemaHash = hashSchemaInput(lookupOutput);
      final binding = <String, dynamic>{
        'v': 1,
        'kind': 'client-tool-execution',
        'interruptId': 'client-1',
        'interruptedRunId': 'untrusted-run',
        'generation': 99,
        'toolName': 'lookup',
        'toolCallId': 'expected-call',
        'outputSchemaHash': outputSchemaHash,
        'responseSchemaHash': outputSchemaHash,
      };
      final manager = InterruptManager(tools: tools);
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 3,
        pending: <Map<String, dynamic>>[
          descriptor(binding,
              overrides: <String, dynamic>{'toolCallId': 'other-call'}),
        ],
      ));

      final item = manager.getInterrupts().single;
      expect(item.kind, 'generic');
      expect(item.threadId, 'thread-1');
      expect(item.interruptedRunId, 'run-1');
      expect(item.generation, 3);
    });

    test('resolves a generic item regardless of its wire response schema', () {
      const responseSchema = <String, dynamic>{
        r'$schema': 'https://json-schema.org/draft/2019-09/schema',
        'type': 'object',
      };
      final binding = <String, dynamic>{
        'v': 1,
        'kind': 'generic',
        'interruptId': 'generic-1',
        'interruptedRunId': 'run-1',
        'generation': 1,
        'responseSchemaHash':
            digestInterruptJson(canonicalInterruptJson(responseSchema)),
      };
      final manager = InterruptManager(
        tools: tools,
        submitSubmission: (_) async {},
      );
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          descriptor(binding, overrides: <String, dynamic>{
            'responseSchema': responseSchema,
          }),
        ],
      ));

      final item = manager.getInterrupts().single;
      expect(item.canResolve, isTrue);
      item.cancel();
      expect(manager.getInterrupts(), isEmpty);
      expect(manager.getResuming(), isTrue);
    });

    test(
        'does not treat a generic binding as resumable when the schema hash does not match',
        () {
      final binding = <String, dynamic>{
        'v': 1,
        'kind': 'generic',
        'interruptId': 'generic-1',
        'interruptedRunId': 'run-1',
        'generation': 1,
        'responseSchemaHash': 'other-hash',
      };
      final manager = InterruptManager(tools: tools);
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          descriptor(binding, overrides: <String, dynamic>{
            'responseSchema': <String, dynamic>{'type': 'object'},
          }),
        ],
      ));

      final item = manager.getInterrupts().single;
      expect(item.kind, 'generic');
      expect(item.canResolve, isFalse);
    });

    test('records a stale error when two first-party items share a batchIndex',
        () {
      const responseSchema = <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'answer': <String, dynamic>{'type': 'number'},
        },
        'required': <String>['answer'],
      };
      final hash = digestInterruptJson(canonicalInterruptJson(responseSchema));
      final first = <String, dynamic>{
        'v': 1,
        'kind': 'generic',
        'interruptId': 'generic-1',
        'interruptedRunId': 'run-1',
        'generation': 1,
        'definitionId': 'approval',
        'key': 'one',
        'batchIndex': 0,
        'responseSchemaHash': hash,
      };
      final second = Map<String, dynamic>.from(first)
        ..['interruptId'] = 'generic-2'
        ..['key'] = 'two';
      final manager = InterruptManager(
        tools: tools,
        interrupts: <ChatInterruptDefinition>[
          ChatInterruptDefinition(
              id: 'approval', responseSchema: responseSchema),
        ],
        submitSubmission: (_) async {},
      );
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          descriptor(first, overrides: <String, dynamic>{
            'responseSchema': responseSchema,
          }),
          descriptor(second, overrides: <String, dynamic>{
            'responseSchema': responseSchema,
          }),
        ],
      ));

      for (final item in manager.getInterrupts()) {
        expect(item.kind, 'generic');
        expect(item.canResolve, isFalse);
        expect(item.status, ChatInterruptStatus.error);
        expect(item.errors.first['code'], 'stale');
      }
    });

    test(
        'hydrates a first-party item from the producer binding and schema hash',
        () {
      const payloadSchema = <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'title': <String, dynamic>{'type': 'string'},
          'boundary': <String, dynamic>{
            'type': 'string',
            'enum': <String>[
              'beforeModel',
              'afterModel',
              'beforeTools',
              'afterTools',
            ],
          },
        },
        'required': <String>['title', 'boundary'],
        'additionalProperties': false,
      };
      const responseSchema = <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'approved': <String, dynamic>{'type': 'boolean'},
          'note': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['approved', 'note'],
        'additionalProperties': false,
      };
      final definition = ChatInterruptDefinition(
        id: 'review-plan',
        payloadSchema: payloadSchema,
        responseSchema: responseSchema,
      );
      final interruptId = 'interrupt-1';
      final binding = <String, dynamic>{
        'v': 1,
        'kind': 'generic',
        'interruptId': interruptId,
        'interruptedRunId': 'run-1',
        'generation': 0,
        'definitionId': 'review-plan',
        'key': 'generic-before-model-review',
        'batchIndex': 0,
        'payloadSchemaHash': hashInterruptDefinitionSchema(payloadSchema),
        'responseSchemaHash': hashInterruptDefinitionSchema(responseSchema),
      };
      final manager = InterruptManager(
        tools: tools,
        interrupts: <ChatInterruptDefinition>[definition],
        submitSubmission: (_) async {},
      );
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 0,
        pending: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': interruptId,
            'reason': 'review_required',
            'message': 'Review the plan at beforeModel',
            'responseSchema': responseSchema,
            'metadata': <String, dynamic>{
              'tanstack:interruptBinding': binding,
              'tanstack:interruptPayload': <String, dynamic>{
                'title': 'Middleware review plan',
                'boundary': 'beforeModel',
              },
            },
          },
        ],
      ));

      final item = manager.getInterrupts().single;
      expect(item.kind, 'generic');
      expect(item.canResolve, isTrue);
      expect(item.definitionId, 'review-plan');
    });
  });

  group('InterruptManager transactions', () {
    test(
        'waits for a complete multi-item batch and submits a singleton immediately',
        () async {
      final multi = ManagerFixture();
      multi.value.hydrate(const ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'one',
            'reason': 'confirmation',
            'metadata': <String, dynamic>{
              'tanstack:interruptBinding': <String, dynamic>{
                'v': 1,
                'kind': 'generic',
                'interruptId': 'one',
                'interruptedRunId': 'run-1',
                'generation': 1,
                'responseSchemaHash': 'none',
              },
            },
          },
          <String, dynamic>{
            'id': 'two',
            'reason': 'confirmation',
            'metadata': <String, dynamic>{
              'tanstack:interruptBinding': <String, dynamic>{
                'v': 1,
                'kind': 'generic',
                'interruptId': 'two',
                'interruptedRunId': 'run-1',
                'generation': 1,
                'responseSchemaHash': 'none',
              },
            },
          },
        ],
      ));
      final first = multi.value.getInterrupts()[0];
      first.resolveInterrupt('first');
      expect(multi.submissions, isEmpty);
      expect(multi.value.getInterrupts()[0].status, ChatInterruptStatus.staged);
      multi.value.getInterrupts()[1].cancel();
      expect(multi.submissions, hasLength(1));
      await settle();

      final single = ManagerFixture();
      single.value.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          genericDescriptor('only'),
        ],
      ));
      single.value.getInterrupts().single.resolveInterrupt('done');
      expect(single.submissions, hasLength(1));
      await settle();
    });

    test(
        'validates async Standard Schema candidates and preserves a prior valid draft',
        () async {
      final asyncTool = ClientTool(
        name: 'asyncLookup',
        outputSchema: lookupOutput,
      );
      final outputSchemaHash = hashSchemaInput(lookupOutput);
      final submissions = <InterruptManagerSubmission>[];
      final manager = InterruptManager(
        tools: <ClientTool>[asyncTool],
        submitSubmission: (submission) async => submissions.add(submission),
      );
      final binding = <String, dynamic>{
        'v': 1,
        'kind': 'client-tool-execution',
        'interruptId': 'async-1',
        'interruptedRunId': 'run-1',
        'generation': 1,
        'toolName': 'asyncLookup',
        'toolCallId': 'call-1',
        'outputSchemaHash': outputSchemaHash,
        'responseSchemaHash': outputSchemaHash,
      };
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          descriptor(binding),
          genericDescriptor('other'),
        ],
      ));

      expect(manager.getInterrupts(), hasLength(1));
      expect(manager.getInterrupts().single.kind, 'generic');
      expect(
        manager.resolveClientToolOutput('call-1', <String, dynamic>{
          'accountId': 'valid',
        }),
        isTrue,
      );
      await settle();
      expect(submissions, isEmpty);

      final generic = manager.getInterrupts().single;
      generic.resolveInterrupt('done');
      await settle();
      expect(submissions, hasLength(1));
    });

    test(
        'rolls callback transactions back on thrown, returned, thenable, or incomplete work',
        () {
      final fixture = ManagerFixture();
      fixture.value.hydrate(const ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'one',
            'reason': 'confirmation',
            'metadata': <String, dynamic>{
              'tanstack:interruptBinding': <String, dynamic>{
                'v': 1,
                'kind': 'generic',
                'interruptId': 'one',
                'interruptedRunId': 'run-1',
                'generation': 1,
                'responseSchemaHash': 'none',
              },
            },
          },
          <String, dynamic>{
            'id': 'two',
            'reason': 'confirmation',
            'metadata': <String, dynamic>{
              'tanstack:interruptBinding': <String, dynamic>{
                'v': 1,
                'kind': 'generic',
                'interruptId': 'two',
                'interruptedRunId': 'run-1',
                'generation': 1,
                'responseSchemaHash': 'none',
              },
            },
          },
        ],
      ));

      fixture.value.resolve((item) {
        throw StateError('transaction failed');
      });
      fixture.value.resolve((item) {
        item.cancel();
        return 'not undefined';
      });
      fixture.value.resolve((item) => Future<void>.value());
      fixture.value.resolve((item) {
        if (item.id == 'one') item.cancel();
        return null;
      });

      expect(fixture.submissions, isEmpty);
      expect(
        fixture.value
            .getInterrupts()
            .every((item) => item.status == ChatInterruptStatus.pending),
        isTrue,
      );
      expect(fixture.value.getInterruptErrors(), hasLength(4));
    });

    test(
        'seals transaction items, invokes the callback once per item, and submits atomically',
        () {
      final fixture = ManagerFixture();
      fixture.value.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          genericDescriptor('one'),
          genericDescriptor('two'),
        ],
      ));
      final calls = <String>[];
      void Function()? lateCancel;
      fixture.value.resolve((item) {
        calls.add(item.id);
        if (item.id == 'one') lateCancel = item.cancel;
        item.cancel();
        return null;
      });

      expect(calls, <String>['one', 'two']);
      expect(fixture.submissions, hasLength(1));
      expect(() => lateCancel?.call(), throwsStateError);
      expect(fixture.value.getInterrupts(), isEmpty);
      expect(fixture.value.getResuming(), isTrue);
    });

    test(
        'permits boolean bulk resolution only for payloadless tool approvals and cancels all payloadlessly',
        () {
      final approvalTool = ClientTool(
        name: 'confirmOnly',
        needsApproval: true,
      );
      final approval = normalizeApprovalSchema(null, null);
      final binding = <String, dynamic>{
        'v': 1,
        'kind': 'tool-approval',
        'interruptId': 'approval-1',
        'interruptedRunId': 'run-1',
        'generation': 1,
        'toolName': 'confirmOnly',
        'toolCallId': 'call-1',
        'originalArgs': <String, dynamic>{},
        'inputSchemaHash': hashSchemaInput(null),
        'approvalSchemaHash': approval.approvalSchemaHash,
        'responseSchemaHash': approval.responseSchemaHash,
      };
      final submissions = <InterruptManagerSubmission>[];
      final approvals = InterruptManager(
        tools: <ClientTool>[approvalTool],
        submitSubmission: (submission) async => submissions.add(submission),
      );
      approvals.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          descriptor(binding, overrides: <String, dynamic>{
            'responseSchema': approval.responseSchema,
          }),
        ],
      ));
      approvals.resolve(true);
      expect(submissions.single.resolutions, <Map<String, dynamic>>[
        <String, dynamic>{
          'interruptId': 'approval-1',
          'status': 'resolved',
          'payload': <String, dynamic>{'approved': true},
        },
      ]);

      final generic = ManagerFixture();
      generic.value.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          genericDescriptor('generic'),
        ],
      ));
      generic.value.resolve(false);
      expect(generic.submissions, isEmpty);
      expect(generic.value.getInterruptErrors().first['code'],
          'unsupported-bulk-operation');
      generic.value.cancel();
      expect(generic.submissions.single.resolutions, <Map<String, dynamic>>[
        <String, dynamic>{
          'interruptId': 'generic',
          'status': 'cancelled',
        },
      ]);
    });

    test('retries the exact frozen batch only for retryable failures',
        () async {
      final retryable = <String, dynamic>{
        'scope': 'batch',
        'code': 'transport',
        'message': 'offline',
        'source': 'transport',
        'retryable': true,
        'interruptIds': <String>['generic'],
        'threadId': 'thread-1',
        'interruptedRunId': 'run-1',
        'generation': 1,
      };
      var calls = 0;
      final submissions = <InterruptManagerSubmission>[];
      final manager = InterruptManager(
        submitSubmission: (submission) async {
          calls++;
          submissions.add(submission);
          if (calls == 1) {
            throw <String, dynamic>{
              'errors': <Map<String, dynamic>>[retryable],
            };
          }
        },
      );
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          genericDescriptor('generic'),
        ],
      ));
      manager.getInterrupts().single.resolveInterrupt('answer');
      await settle();

      final firstSubmission = submissions.first;
      manager.retry();
      expect(submissions[1], same(firstSubmission));
      await settle();

      manager.retry();
      expect(calls, 2);
    });

    test('ignores a submission failure after reset', () async {
      final operation = Completer<void>();
      final manager = InterruptManager(
        submitSubmission: (_) => operation.future,
      );
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          genericDescriptor('generic'),
        ],
      ));
      manager.getInterrupts().single.resolveInterrupt('answer');
      manager.reset();
      final resetState = manager.getState();
      operation.completeError(StateError('offline'));
      await settle();

      expect(manager.getState(), same(resetState));
      expect(manager.getInterruptErrors(), isEmpty);
      expect(manager.getResuming(), isFalse);
    });

    test('does not let a stale submission settle a rehydrated submission',
        () async {
      final operations = <Completer<void>>[];
      final manager = InterruptManager(
        submitSubmission: (_) {
          final completer = Completer<void>();
          operations.add(completer);
          return completer.future;
        },
      );
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[genericDescriptor('old')],
      ));
      manager.getInterrupts().single.resolveInterrupt('old answer');

      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-2',
        threadId: 'thread-1',
        generation: 2,
        pending: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'current',
            'reason': 'confirmation',
            'metadata': <String, dynamic>{
              'tanstack:interruptBinding': <String, dynamic>{
                'v': 1,
                'kind': 'generic',
                'interruptId': 'current',
                'interruptedRunId': 'run-2',
                'generation': 2,
                'responseSchemaHash': 'none',
              },
            },
          },
        ],
      ));
      manager.getInterrupts().single.resolveInterrupt('current answer');
      expect(operations, hasLength(2));

      operations[0].completeError(StateError('old failure'));
      await settle();
      expect(manager.getInterruptErrors(), isEmpty);
      expect(manager.getResuming(), isTrue);
      expect(manager.getInterrupts(), isEmpty);

      operations[1].complete();
      await settle();
      expect(manager.getResuming(), isFalse);
    });

    test('does not enable retry for expired/stale/conflict server failures',
        () async {
      for (final code in <String>['expired', 'stale', 'conflict']) {
        var calls = 0;
        final manager = InterruptManager(
          submitSubmission: (_) async {
            calls++;
            throw <String, dynamic>{
              'errors': <Map<String, dynamic>>[
                <String, dynamic>{
                  'scope': 'batch',
                  'code': code,
                  'message': '$code failure',
                  'source': 'server',
                  'retryable': true,
                  'interruptIds': <String>['generic'],
                  'threadId': 'thread-1',
                  'interruptedRunId': 'run-1',
                  'generation': 1,
                },
              ],
            };
          },
        );
        manager.hydrate(ChatHydrationInterrupts(
          runId: 'run-1',
          threadId: 'thread-1',
          generation: 1,
          pending: <Map<String, dynamic>>[genericDescriptor('generic')],
        ));
        manager.getInterrupts().single.resolveInterrupt('answer');
        await settle();
        expect(
            manager.getInterruptErrors().any((error) => error['code'] == code),
            isTrue);
        manager.retry();
        expect(calls, 1);
      }
    });

    test('surfaces client-tool validation failures on interruptErrors',
        () async {
      final outputSchemaHash = hashSchemaInput(lookupOutput);
      final binding = <String, dynamic>{
        'v': 1,
        'kind': 'client-tool-execution',
        'interruptId': 'client-1',
        'interruptedRunId': 'run-1',
        'generation': 1,
        'toolName': 'lookup',
        'toolCallId': 'call-1',
        'outputSchemaHash': outputSchemaHash,
        'responseSchemaHash': outputSchemaHash,
      };
      final manager = InterruptManager(tools: tools);
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[descriptor(binding)],
      ));
      expect(
          manager.resolveClientToolOutput('call-1', {'wrong': true}), isTrue);
      await settle();
      expect(manager.getInterrupts(), isEmpty);
      expect(
          manager
              .getInterruptErrors()
              .any((error) => error['code'] == 'item-validation-failed'),
          isTrue);
    });

    test('stages client-tool errors without validating the success schema',
        () async {
      final outputSchemaHash = hashSchemaInput(lookupOutput);
      final binding = <String, dynamic>{
        'v': 1,
        'kind': 'client-tool-execution',
        'interruptId': 'client-1',
        'interruptedRunId': 'run-1',
        'generation': 1,
        'toolName': 'lookup',
        'toolCallId': 'call-1',
        'outputSchemaHash': outputSchemaHash,
        'responseSchemaHash': outputSchemaHash,
      };
      final submissions = <InterruptManagerSubmission>[];
      final manager = InterruptManager(
        tools: tools,
        submitSubmission: (submission) async => submissions.add(submission),
      );
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[descriptor(binding)],
      ));

      expect(manager.resolveClientToolError('call-1', 'Lookup failed'), isTrue);
      await settle();

      expect(submissions.single.resolutions, <Map<String, dynamic>>[
        <String, dynamic>{
          'interruptId': 'client-1',
          'status': 'resolved',
          'payload': <String, dynamic>{'error': 'Lookup failed'},
          'metadata': <String, dynamic>{
            'tanstack': <String, dynamic>{'state': 'output-error'},
          },
        },
      ]);
    });

    test('reports client-tool canonicalization failures as invalid output',
        () async {
      final canonicalTool = ClientTool(name: 'canonical');
      final outputSchemaHash = hashSchemaInput(null);
      final manager = InterruptManager(
        tools: <ClientTool>[canonicalTool],
        submitSubmission: (_) async {},
      );
      final binding = <String, dynamic>{
        'v': 1,
        'kind': 'client-tool-execution',
        'interruptId': 'client-1',
        'interruptedRunId': 'run-1',
        'generation': 1,
        'toolName': 'canonical',
        'toolCallId': 'call-1',
        'outputSchemaHash': outputSchemaHash,
        'responseSchemaHash': outputSchemaHash,
      };
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[descriptor(binding)],
      ));

      expect(manager.resolveClientToolOutput('call-1', Object()), isTrue);
      await settle();
      expect(
          manager
              .getInterruptErrors()
              .any((error) => error['code'] == 'item-validation-failed'),
          isTrue);
    });

    test('resolves pre-binding client-tool fallback with raw output', () {
      final submissions = <InterruptManagerSubmission>[];
      final manager = InterruptManager(
        tools: tools,
        submitSubmission: (submission) async => submissions.add(submission),
      );
      manager.hydrate(const ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'client-degraded',
            'reason': 'tanstack:client_tool_execution',
            'toolCallId': 'call-degraded',
            'metadata': <String, dynamic>{
              'kind': 'client_tool',
              'toolName': 'lookup',
              'input': <String, dynamic>{},
            },
          },
        ],
      ));
      expect(manager.getInterrupts().single.kind, 'generic');
      expect(
          manager.resolveClientToolOutput(
              'call-degraded', <String, dynamic>{'accountId': 'a'}),
          isTrue);
      expect(submissions.single.resolutions, <Map<String, dynamic>>[
        <String, dynamic>{
          'interruptId': 'client-degraded',
          'status': 'resolved',
          'payload': <String, dynamic>{'accountId': 'a'},
        },
      ]);
    });

    test(
        'supersedes a server batch error set without dropping local client, transport, or item errors',
        () async {
      final firstErrors = <Map<String, dynamic>>[
        <String, dynamic>{
          'scope': 'batch',
          'code': 'incomplete-batch',
          'message': 'first incomplete batch',
          'source': 'client',
          'retryable': false,
          'interruptIds': <String>['generic'],
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
        <String, dynamic>{
          'scope': 'batch',
          'code': 'item-validation-failed',
          'message': 'first aggregate validation failure',
          'source': 'client',
          'retryable': false,
          'interruptIds': <String>['generic'],
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
        <String, dynamic>{
          'scope': 'item',
          'interruptId': 'generic',
          'code': 'unknown-interrupt',
          'message': 'first item failure',
          'source': 'client',
          'retryable': false,
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
        <String, dynamic>{
          'scope': 'batch',
          'code': 'transport',
          'message': 'transport failure remains locally actionable',
          'source': 'transport',
          'retryable': false,
          'interruptIds': <String>['generic'],
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
      ];
      final secondErrors = <Map<String, dynamic>>[
        <String, dynamic>{
          'scope': 'batch',
          'code': 'incomplete-batch',
          'message': 'updated incomplete batch',
          'source': 'client',
          'retryable': false,
          'interruptIds': <String>['generic'],
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
        <String, dynamic>{
          'scope': 'batch',
          'code': 'server',
          'message': 'a distinct server failure',
          'source': 'client',
          'retryable': false,
          'interruptIds': <String>['generic'],
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
        <String, dynamic>{
          'scope': 'item',
          'interruptId': 'generic',
          'code': 'unknown-interrupt',
          'message': 'updated item failure',
          'source': 'client',
          'retryable': false,
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
      ];
      var calls = 0;
      final manager = InterruptManager(
        submitSubmission: (submission) async {
          calls++;
          throw <String, dynamic>{
            'errors': calls == 1 ? firstErrors : secondErrors,
          };
        },
      );
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[genericDescriptor('generic')],
      ));

      manager.resolve((item) => null);
      manager.getInterrupts().single.resolveInterrupt('first answer');
      await settle();
      manager.getInterrupts().single.clearResolution();
      manager.getInterrupts().single.resolveInterrupt('second answer');
      await settle();

      expect(manager.getInterruptErrors(), <Map<String, dynamic>>[
        <String, dynamic>{
          'scope': 'batch',
          'code': 'incomplete-batch',
          'message': 'Interrupt transaction did not resolve every item.',
          'source': 'client',
          'retryable': false,
          'interruptIds': <String>['generic'],
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
        <String, dynamic>{
          'scope': 'batch',
          'code': 'transport',
          'message': 'transport failure remains locally actionable',
          'source': 'transport',
          'retryable': false,
          'interruptIds': <String>['generic'],
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
        <String, dynamic>{
          'scope': 'batch',
          'code': 'incomplete-batch',
          'message': 'updated incomplete batch',
          'source': 'client',
          'retryable': false,
          'interruptIds': <String>['generic'],
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
        <String, dynamic>{
          'scope': 'batch',
          'code': 'server',
          'message': 'a distinct server failure',
          'source': 'client',
          'retryable': false,
          'interruptIds': <String>['generic'],
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
      ]);
      expect(manager.getInterrupts().single.errors, <Map<String, dynamic>>[
        <String, dynamic>{
          'scope': 'item',
          'interruptId': 'generic',
          'code': 'unknown-interrupt',
          'message': 'updated item failure',
          'source': 'client',
          'retryable': false,
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
      ]);
    });

    test(
        'rejects submission errors that do not correlate to the active interrupt batch',
        () async {
      final foreignErrors = <Map<String, dynamic>>[
        <String, dynamic>{
          'scope': 'item',
          'interruptId': 'generic',
          'code': 'unknown-interrupt',
          'message': 'foreign thread',
          'source': 'server',
          'retryable': false,
          'threadId': 'other-thread',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
        <String, dynamic>{
          'scope': 'item',
          'interruptId': 'generic',
          'code': 'unknown-interrupt',
          'message': 'foreign run',
          'source': 'server',
          'retryable': false,
          'threadId': 'thread-1',
          'interruptedRunId': 'other-run',
          'generation': 1,
        },
        <String, dynamic>{
          'scope': 'item',
          'interruptId': 'generic',
          'code': 'unknown-interrupt',
          'message': 'foreign generation',
          'source': 'server',
          'retryable': false,
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 2,
        },
        <String, dynamic>{
          'scope': 'item',
          'interruptId': 'other-interrupt',
          'code': 'unknown-interrupt',
          'message': 'foreign item',
          'source': 'server',
          'retryable': false,
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
        <String, dynamic>{
          'scope': 'batch',
          'code': 'item-validation-failed',
          'message': 'foreign batch',
          'source': 'server',
          'retryable': false,
          'interruptIds': <String>['other-interrupt'],
          'threadId': 'thread-1',
          'interruptedRunId': 'run-1',
          'generation': 1,
        },
      ];
      final manager = InterruptManager(
        submitSubmission: (_) async => throw <String, dynamic>{
          'errors': foreignErrors,
        },
      );
      manager.hydrate(ChatHydrationInterrupts(
        runId: 'run-1',
        threadId: 'thread-1',
        generation: 1,
        pending: <Map<String, dynamic>>[genericDescriptor('generic')],
      ));
      manager.getInterrupts().single.resolveInterrupt('answer');
      await settle();

      expect(manager.getInterrupts().single.errors, isEmpty);
      expect(manager.getInterruptErrors(), hasLength(1));
      expect(manager.getInterruptErrors().single, <String, dynamic>{
        'scope': 'batch',
        'code': 'protocol',
        'message':
            'Interrupt submission errors did not match the active batch.',
        'source': 'client',
        'retryable': false,
        'interruptIds': <String>['generic'],
        'threadId': 'thread-1',
        'interruptedRunId': 'run-1',
        'generation': 1,
      });
    });
  });
}

Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
