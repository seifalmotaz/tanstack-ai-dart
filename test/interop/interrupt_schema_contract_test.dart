// Upstream reference: packages/ai/src/interrupt-serialization.ts,
// interrupt-definition.ts and activities/chat/tools/approval-schema.ts.
//
// Golden strings and hashes below were produced by the pinned upstream
// JavaScript build (`@tanstack/ai/dist/esm`), not by this Dart port.
import 'package:tanstack_ai_dart/chat.dart';
import 'package:tanstack_ai_dart/platform.dart';
import 'package:test/test.dart';

const String sortUnicodeCanonical = r'{"\u0001":4,"a":"line\n'
    '\u2028\u2029\ud83d\ude00\\"\\\\/",'
    '"e":2,"é":1,"😀":3}';
const String sortUnicodeHash =
    'sha256:a72505c7f9ea9c78640cffa5b18e619ac61bc4120fcf92357f0b3a47b86c3790';

const String numbersCanonical =
    '[0,0,1,1.5,100000000000000000000,1e+21,0.000001,1e-7,'
    '123456789012345680000,5e-324,1.7976931348623157e+308,0.1,'
    '0.30000000000000004,1.2345678901234566e-9,1.2345678901234566e+25]';
const String numbersHash =
    'sha256:8a09fa87b7b3fb83cb1f298efeab4e3cbb0fe6be64b3689487c06de8e12c7afa';
const String nestedHash =
    'sha256:fb340c25028e2fff507227054403f7c217264cbdcb81e76f3175785265dc7a93';

const String undefinedInputHash =
    'sha256:eb045d78d273107348b0300c01d29b7552d622abbc6faf81b3ec55359aa9950c';
const String rawInputHash =
    'sha256:b2c8796eed8f081f16e939fec00a52a7088192511c9d3fb4224c3cae371ec271';
const String standardJsonHash =
    'sha256:fda26da4f4c8ffc36ffc00f4d0d7ee3407dcc9d52acb703119cb83dc42bcd25b';
const String standardNoJsonHash =
    'sha256:9c8b84510085f6445c54264bc305ecefbda1ce05f16fa6413953b660abfc7638';
const String definitionStdHash =
    'sha256:010b1dec865519f00e024db52d4deeb3dc5d7dc08390f0e455f5338dbde231c7';

const String approvalUndefinedUndefinedResponse =
    'sha256:ed82fe780755de70bdc8e477ffff9696d7dd16dd9b328a62a9d2d85525ba6b96';
const String approvalUndefinedInputResponse =
    'sha256:9ecdecd4565bddc507409b11e8662a0e4bf5c225e249f837235310282d4a11c4';
const String approvalRawInputResponse =
    'sha256:8337a80fafe1f2011ad90bd78ea476bc5e62021d076679d48f8aaa398549dee2';
const String approvalRawInputApproval =
    'sha256:3eb3e6edae2968bad39ad89ad1b754438273f979f73960926e40b6849992f62e';
const String approvalBranchesResponse =
    'sha256:bae89b74cdf6172e060051d641d52b6e26dc3814c89a0340d1eda144729acd63';
const String approvalBranchesApproval =
    'sha256:c2bd983d89b7c638795ee871685217cb39094e504ab1c5fa2f54d5b17e0c05a8';
const String approvalApproveOnlyResponse =
    'sha256:f38482bd1c3fc824f9a663034ca52c96b7973bb36dc4156ab24592260ce9011e';
const String approvalRejectOnlyResponse =
    'sha256:be317650be1ee8792391ba72bfcce6058692af08d067ac0cdea86d8ca015933d';
const String approvalRawNoInputResponse =
    'sha256:61d4d0d04cc8337a056b3d666cf74a729b02c7a1425b52256d433a205cca0784';
const String approvalEmptyHash =
    'sha256:22f76d9a1c618a3cfaa891208a14f6e5e6ab1be4ff1c38cc8a8cd1e8fd0c0e4e';

const String outputSchemaHash =
    'sha256:289529b9109f1dccbfc2a94bc9d8ecbe5f349e11f34b64ab2e21c38ce794b55c';
const String genericResponseHash =
    'sha256:d7f69ea25824f613d0b60198abe050adc66a3bf45d9f2045d1997214a55498e5';

const Map<String, dynamic> rawInput = <String, dynamic>{
  'type': 'object',
  'properties': <String, dynamic>{
    'amount': <String, dynamic>{'type': 'number'},
    'currency': <String, dynamic>{
      'type': 'string',
      'enum': <String>['USD', 'EUR'],
    },
  },
  'required': <String>['amount', 'currency'],
  'additionalProperties': false,
};

const Map<String, dynamic> rawApprove = <String, dynamic>{
  'type': 'object',
  'properties': <String, dynamic>{
    'note': <String, dynamic>{'type': 'string'},
  },
  'required': <String>['note'],
  'additionalProperties': false,
};

const Map<String, dynamic> rawReject = <String, dynamic>{
  'type': 'string',
  'minLength': 1,
};

const Map<String, dynamic> rawOutput = <String, dynamic>{
  'type': 'object',
  'properties': <String, dynamic>{
    'result': <String, dynamic>{'type': 'string'},
    'confidence': <String, dynamic>{
      'type': 'number',
      'minimum': 0,
      'maximum': 1,
    },
  },
  'required': <String>['result'],
  'additionalProperties': false,
};

const Map<String, dynamic> rawResponse = <String, dynamic>{
  'type': 'object',
  'properties': <String, dynamic>{
    'answer': <String, dynamic>{'type': 'string'},
  },
  'required': <String>['answer'],
  'additionalProperties': false,
};

Map<String, dynamic> descriptor(
  Map<String, dynamic> binding, {
  String id = 'i1',
  String toolCallId = 'tc1',
  Map<String, dynamic>? metadata,
}) =>
    <String, dynamic>{
      'id': id,
      'reason': 'approval_required',
      'toolCallId': toolCallId,
      'metadata': metadata ??
          <String, dynamic>{
            'kind': 'approval',
            'toolName': 'pay',
            'input': <String, dynamic>{},
            'tanstack:interruptBinding': binding,
          },
    };

Map<String, dynamic> binding({
  required String kind,
  String id = 'i1',
  String runId = 'r',
  String toolName = 'pay',
  String toolCallId = 'tc1',
  Map<String, dynamic> extra = const <String, dynamic>{},
}) =>
    <String, dynamic>{
      'v': 1,
      'kind': kind,
      'interruptId': id,
      'interruptedRunId': runId,
      'generation': 1,
      'toolName': toolName,
      'toolCallId': toolCallId,
      ...extra,
    };

void main() {
  group('canonicalInterruptJson JS goldens', () {
    test('sorts keys by UTF-16 and escapes like JSON.stringify', () {
      final value = <String, dynamic>{
        'é': 1,
        'e': 2,
        '😀': 3,
        String.fromCharCode(1): 4,
        'a': 'line\n\u2028\u2029\ud83d\ude00"\\/',
      };
      expect(canonicalInterruptJson(value), sortUnicodeCanonical);
      expect(
          digestInterruptJson(canonicalInterruptJson(value)), sortUnicodeHash);
    });

    test('formats finite numbers exactly like ECMAScript', () {
      final value = <num>[
        0,
        -0.0,
        1,
        1.5,
        1e20,
        1e21,
        1e-6,
        1e-7,
        1.2345678901234568e20,
        5e-324,
        1.7976931348623157e308,
        0.1,
        0.30000000000000004,
        1.2345678901234567e-9,
        1.2345678901234567e+25,
      ];
      expect(canonicalInterruptJson(value), numbersCanonical);
      expect(digestInterruptJson(canonicalInterruptJson(value)), numbersHash);
    });

    test('sorts nested objects and keeps array order', () {
      final value = <String, dynamic>{
        'z': <dynamic>[
          null,
          true,
          false,
          <String, dynamic>{
            'b': 'x',
            'a': <int>[1, 2],
          },
        ],
        'a': <String, dynamic>{},
      };
      expect(digestInterruptJson(canonicalInterruptJson(value)), nestedHash);
    });

    test('escapes lone surrogates and control characters like JSON.stringify',
        () {
      expect(canonicalInterruptJson(String.fromCharCode(0xD800)), r'"\ud800"');
      expect(canonicalInterruptJson('a${String.fromCharCode(0xDC00)}b'),
          r'"a\udc00b"');
      expect(canonicalInterruptJson('\b\f\n\r\t'), r'"\b\f\n\r\t"');
      expect(canonicalInterruptJson('\u0000\u001f\u007f'),
          r'"\u0000\u001f' '\u007f"');
    });

    test('rejects values JSON cannot carry', () {
      expect(() => canonicalInterruptJson(double.nan), throwsArgumentError);
      expect(
          () => canonicalInterruptJson(double.infinity), throwsArgumentError);
      expect(canonicalInterruptJson(<dynamic>[]), '[]');
      expect(() => canonicalInterruptJson((Object a, Object b) => 1),
          throwsArgumentError);
      expect(() => canonicalInterruptJson(DateTime.now()), throwsArgumentError);
      expect(() => canonicalInterruptJson(Object()), throwsArgumentError);
      expect(() => canonicalInterruptJson(<int, String>{1: 'x'}),
          throwsArgumentError);
      expect(() => canonicalInterruptJson(BigInt.one), throwsArgumentError);
      final cycle = <String, dynamic>{};
      cycle['self'] = cycle;
      expect(() => canonicalInterruptJson(cycle), throwsArgumentError);
    });
  });

  group('schema hashes match the JS producer', () {
    final standardJson = StandardSchema(
      (value) => SchemaValidationResult.success(value),
      schema: <String, dynamic>{
        r'$schema': 'https://json-schema.org/draft/2020-12/schema',
        'type': 'string',
        'format': 'email',
      },
    );
    final standardNoJson = StandardSchema(
      (value) => SchemaValidationResult.success(value),
    );

    test('hashes undefined input as the literal undefined text', () {
      expect(hashSchemaInput(null), undefinedInputHash);
    });

    test('hashes raw JSON Schema as carried', () {
      expect(hashSchemaInput(rawInput), rawInputHash);
    });

    test('keeps \$schema for schema inputs and strips it for definitions', () {
      expect(hashSchemaInput(standardJson), standardJsonHash);
      expect(hashInterruptDefinitionSchema(standardJson), definitionStdHash);
      expect(standardJsonHash, isNot(definitionStdHash));
    });

    test('hashes a Standard Schema without a converter as unserialized', () {
      expect(hashSchemaInput(standardNoJson), standardNoJsonHash);
    });

    test('hashes interrupt definition schemas', () {
      expect(hashInterruptDefinitionSchema(standardJson), definitionStdHash);
      expect(() => hashInterruptDefinitionSchema(standardNoJson),
          throwsArgumentError);
    });

    test('default hash is prefixed sha256', () {
      expect(defaultInterruptHash('abc'),
          'sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(
          digestInterruptJson('abc', (text) => 'custom:$text'), 'custom:abc');
    });
  });

  group('normalizeApprovalSchema JS goldens', () {
    test('hashes the payloadless response envelope', () {
      final normalized = normalizeApprovalSchema(null);
      expect(normalized.responseSchemaHash, approvalUndefinedUndefinedResponse);
      expect(normalized.approvalSchemaHash, approvalEmptyHash);
    });

    test('includes the input schema in the accepted editedArgs branch', () {
      final normalized = normalizeApprovalSchema(null, rawInput);
      expect(normalized.responseSchemaHash, approvalUndefinedInputResponse);
      expect(normalized.approvalSchemaHash, approvalEmptyHash);
    });

    test('normalizes a single approval schema into both branches', () {
      final normalized = normalizeApprovalSchema(rawApprove, rawInput);
      expect(normalized.responseSchemaHash, approvalRawInputResponse);
      expect(normalized.approvalSchemaHash, approvalRawInputApproval);
    });

    test('normalizes approve/reject branches independently', () {
      final normalized = normalizeApprovalSchema(<String, dynamic>{
        'approve': rawApprove,
        'reject': rawReject,
      }, rawInput);
      expect(normalized.responseSchemaHash, approvalBranchesResponse);
      expect(normalized.approvalSchemaHash, approvalBranchesApproval);
    });

    test('accepts approve-only and reject-only branch maps', () {
      expect(
        normalizeApprovalSchema(
                <String, dynamic>{'approve': rawApprove}, rawInput)
            .responseSchemaHash,
        approvalApproveOnlyResponse,
      );
      expect(
        normalizeApprovalSchema(
                <String, dynamic>{'reject': rawReject}, rawInput)
            .responseSchemaHash,
        approvalRejectOnlyResponse,
      );
    });

    test('hashes approval without an input schema', () {
      expect(normalizeApprovalSchema(rawApprove).responseSchemaHash,
          approvalRawNoInputResponse);
    });

    test('rejects an empty approval map', () {
      expect(() => normalizeApprovalSchema(<String, dynamic>{}),
          throwsArgumentError);
    });
  });

  group('signed schema ownership', () {
    test('grants a tool approval only when all three hashes match', () {
      final tool = ClientTool(
        name: 'pay',
        needsApproval: true,
        inputSchema: rawInput,
        approvalSchema: rawApprove,
      );
      final manager = InterruptManager(tools: <ClientTool>[tool]);
      manager.hydrate(
        ChatHydrationInterrupts(
          runId: 'r',
          pending: <Map<String, dynamic>>[
            descriptor(binding(
              kind: 'tool-approval',
              extra: <String, dynamic>{
                'inputSchemaHash': rawInputHash,
                'approvalSchemaHash': approvalRawInputApproval,
                'responseSchemaHash': approvalRawInputResponse,
              },
            )),
          ],
        ),
      );

      final interrupt = manager.getInterrupts().single;
      expect(interrupt.kind, 'tool-approval');
      expect(interrupt.canResolve, isTrue);
    });

    for (final entry in <String, String>{
      'input': 'sha256:wrong-input',
      'approval': 'sha256:wrong-approval',
      'response': 'sha256:wrong-response',
    }.entries) {
      test('rejects a tool approval with a mismatched ${entry.key} hash', () {
        final tool = ClientTool(
          name: 'pay',
          needsApproval: true,
          inputSchema: rawInput,
          approvalSchema: rawApprove,
        );
        final manager = InterruptManager(tools: <ClientTool>[tool]);
        final hashes = <String, dynamic>{
          'inputSchemaHash': rawInputHash,
          'approvalSchemaHash': approvalRawInputApproval,
          'responseSchemaHash': approvalRawInputResponse,
        };
        hashes['${entry.key}SchemaHash'] = entry.value;
        manager.hydrate(
          ChatHydrationInterrupts(
            runId: 'r',
            pending: <Map<String, dynamic>>[
              descriptor(binding(
                kind: 'tool-approval',
                extra: hashes,
              )),
            ],
          ),
        );

        final interrupt = manager.getInterrupts().single;
        expect(interrupt.kind, 'generic');
      });
    }

    test('grants a client tool only when its output schema hash matches', () {
      final tool = ClientTool(name: 'lookup', outputSchema: rawOutput);
      final manager = InterruptManager(tools: <ClientTool>[tool]);
      manager.hydrate(
        ChatHydrationInterrupts(
          runId: 'r',
          pending: <Map<String, dynamic>>[
            descriptor(
              binding(
                kind: 'client-tool-execution',
                toolName: 'lookup',
                extra: <String, dynamic>{
                  'outputSchemaHash': outputSchemaHash,
                  'responseSchemaHash': outputSchemaHash,
                },
              ),
              metadata: <String, dynamic>{
                'kind': 'client_tool',
                'toolName': 'lookup',
                'input': <String, dynamic>{},
                'tanstack:interruptBinding': binding(
                  kind: 'client-tool-execution',
                  toolName: 'lookup',
                  extra: <String, dynamic>{
                    'outputSchemaHash': outputSchemaHash,
                    'responseSchemaHash': outputSchemaHash,
                  },
                ),
              },
            ),
          ],
        ),
      );

      // Correctly verified client-tool items are internal only.
      expect(manager.getInterrupts(), isEmpty);
      expect(
        manager.resolveClientToolOutput('tc1', <String, dynamic>{
          'result': 'ok',
        }),
        isTrue,
      );
    });

    test('rejects a client tool with a mismatched output schema hash', () {
      final tool = ClientTool(name: 'lookup', outputSchema: rawOutput);
      final manager = InterruptManager(tools: <ClientTool>[tool]);
      final mismatched = binding(
        kind: 'client-tool-execution',
        toolName: 'lookup',
        extra: <String, dynamic>{
          'outputSchemaHash': 'sha256:configured-schema-drift',
          'responseSchemaHash': outputSchemaHash,
        },
      );
      manager.hydrate(
        ChatHydrationInterrupts(
          runId: 'r',
          pending: <Map<String, dynamic>>[
            descriptor(
              mismatched,
              metadata: <String, dynamic>{
                'kind': 'client_tool',
                'toolName': 'lookup',
                'input': <String, dynamic>{},
                'tanstack:interruptBinding': mismatched,
              },
            ),
          ],
        ),
      );

      final interrupt = manager.getInterrupts().single;
      expect(interrupt.kind, 'generic');
    });

    test('accepts a matching raw response schema hash', () {
      final manager = InterruptManager();
      manager.hydrate(
        ChatHydrationInterrupts(
          runId: 'r',
          pending: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'i1',
              'reason': 'choose',
              'responseSchema': rawResponse,
              'metadata': <String, dynamic>{
                'tanstack:interruptBinding': binding(
                  kind: 'generic',
                  id: 'i1',
                  extra: <String, dynamic>{
                    'responseSchemaHash': genericResponseHash,
                  },
                ),
              },
            },
          ],
        ),
      );

      final interrupt = manager.getInterrupts().single;
      expect(interrupt.kind, 'generic');
      expect(interrupt.canResolve, isTrue);
    });

    test('rejects a mismatched raw response schema hash', () {
      final manager = InterruptManager();
      manager.hydrate(
        ChatHydrationInterrupts(
          runId: 'r',
          pending: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'i1',
              'reason': 'choose',
              'responseSchema': rawResponse,
              'metadata': <String, dynamic>{
                'tanstack:interruptBinding': binding(
                  kind: 'generic',
                  id: 'i1',
                  extra: <String, dynamic>{
                    'responseSchemaHash': 'sha256:other-hash',
                  },
                ),
              },
            },
          ],
        ),
      );

      final interrupt = manager.getInterrupts().single;
      expect(interrupt.kind, 'generic');
      expect(interrupt.canResolve, isFalse);
    });

    test('verifies a first-party definition response schema hash', () {
      final definitionSchema = StandardSchema(
        (value) => SchemaValidationResult.success(value),
        schema: rawResponse,
      );
      final expected = hashInterruptDefinitionSchema(definitionSchema);
      final manager = InterruptManager(
        interrupts: <ChatInterruptDefinition>[
          ChatInterruptDefinition(id: 'plan', responseSchema: definitionSchema),
        ],
      );
      Map<String, dynamic> item(String responseHash) => <String, dynamic>{
            'id': 'i1',
            'reason': 'choose',
            'responseSchema': rawResponse,
            'metadata': <String, dynamic>{
              'tanstack:interruptBinding': binding(
                kind: 'generic',
                id: 'i1',
                extra: <String, dynamic>{
                  'definitionId': 'plan',
                  'key': 'k',
                  'batchIndex': 0,
                  'responseSchemaHash': responseHash,
                },
              ),
            },
          };

      manager.hydrate(
        ChatHydrationInterrupts(
          runId: 'r',
          pending: <Map<String, dynamic>>[item(expected)],
        ),
      );
      expect(manager.getInterrupts().single.canResolve, isTrue);

      manager.hydrate(
        ChatHydrationInterrupts(
          runId: 'r',
          pending: <Map<String, dynamic>>[item('sha256:wrong-definition')],
        ),
      );
      final rejected = manager.getInterrupts().single;
      expect(rejected.canResolve, isFalse);
      expect(rejected.status, ChatInterruptStatus.error);
    });

    test('rejects unsigned bindings that claim typed tool approval', () {
      final tool = ClientTool(
        name: 'pay',
        needsApproval: true,
        inputSchema: rawInput,
      );
      final manager = InterruptManager(tools: <ClientTool>[tool]);
      manager.hydrate(
        ChatHydrationInterrupts(
          runId: 'r',
          pending: <Map<String, dynamic>>[
            descriptor(binding(kind: 'tool-approval')),
          ],
        ),
      );

      expect(manager.getInterrupts().single.kind, 'generic');
    });

    test('rejects a legacy tool binding with an unverifiable output hash', () {
      final tool = const ChatClientTool(name: 'lookup');
      final manager = InterruptManager(tools: <ClientTool>[tool]);
      manager.hydrate(
        ChatHydrationInterrupts(
          runId: 'r',
          pending: <Map<String, dynamic>>[
            descriptor(
              binding(
                kind: 'client-tool-execution',
                toolName: 'lookup',
                extra: <String, dynamic>{
                  'outputSchemaHash': 'sha256:legacy-unverifiable',
                  'responseSchemaHash': 'sha256:legacy-unverifiable',
                },
              ),
              metadata: <String, dynamic>{
                'kind': 'client_tool',
                'toolName': 'lookup',
                'input': <String, dynamic>{},
                'tanstack:interruptBinding': binding(
                  kind: 'client-tool-execution',
                  toolName: 'lookup',
                  extra: <String, dynamic>{
                    'outputSchemaHash': 'sha256:legacy-unverifiable',
                    'responseSchemaHash': 'sha256:legacy-unverifiable',
                  },
                ),
              },
            ),
          ],
        ),
      );

      expect(manager.getInterrupts().single.kind, 'generic');
    });
  });
}
