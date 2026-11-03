// Captured from pinned upstream 1.0.1; see tool/capture_upstream_subagent.cjs.
const upstreamSubagentFixture = r'''
[
  [
    {
      "type": "RUN_STARTED",
      "threadId": "t",
      "runId": "run-1",
      "timestamp": 1
    },
    {
      "type": "SUBAGENT_STARTED",
      "subagentRunId": "subagent-1",
      "name": "cleaner",
      "description": "Deletes files",
      "timestamp": 1,
      "metadata": {
        "tanstack": {
          "subagentPlan": {
            "steps": [
              {
                "names": [
                  "cleaner"
                ]
              }
            ]
          }
        }
      },
      "subagentPlan": {
        "steps": [
          {
            "names": [
              "cleaner"
            ]
          }
        ]
      }
    },
    {
      "type": "TOOL_CALL_START",
      "toolCallId": "call_c",
      "toolCallName": "deleteFile",
      "timestamp": 1,
      "metadata": {
        "tanstack": {
          "source": {
            "provider": "scripted",
            "api": "text",
            "model": "test-model"
          }
        }
      },
      "subagentRunId": "subagent-1",
      "source": {
        "provider": "scripted",
        "api": "text",
        "model": "test-model"
      }
    },
    {
      "type": "TOOL_CALL_ARGS",
      "toolCallId": "call_c",
      "delta": "{\"path\":\"a\"}",
      "timestamp": 1,
      "metadata": {
        "tanstack": {
          "source": {
            "provider": "scripted",
            "api": "text",
            "model": "test-model"
          }
        }
      },
      "subagentRunId": "subagent-1",
      "source": {
        "provider": "scripted",
        "api": "text",
        "model": "test-model"
      }
    },
    {
      "type": "SUBAGENT_FINISHED",
      "subagentRunId": "subagent-1",
      "outcome": {
        "type": "suspended",
        "interruptIds": [
          "approval_call_c"
        ]
      },
      "timestamp": 1
    },
    {
      "type": "RUN_FINISHED",
      "threadId": "t",
      "runId": "run-1",
      "outcome": {
        "type": "interrupt",
        "interrupts": [
          {
            "id": "approval_call_c",
            "reason": "tool_call",
            "message": "Approval required to run deleteFile",
            "toolCallId": "call_c",
            "responseSchema": {
              "oneOf": [
                {
                  "type": "object",
                  "properties": {
                    "approved": {
                      "const": true
                    },
                    "editedArgs": {
                      "$schema": "https://json-schema.org/draft/2020-12/schema",
                      "type": "object",
                      "properties": {
                        "path": {
                          "type": "string"
                        }
                      },
                      "required": [
                        "path"
                      ]
                    }
                  },
                  "required": [
                    "approved"
                  ],
                  "additionalProperties": false
                },
                {
                  "type": "object",
                  "properties": {
                    "approved": {
                      "const": false
                    }
                  },
                  "required": [
                    "approved"
                  ],
                  "additionalProperties": false
                }
              ]
            },
            "metadata": {
              "kind": "approval",
              "toolName": "deleteFile",
              "input": {
                "path": "a"
              },
              "tanstack:interruptBinding": {
                "v": 1,
                "kind": "tool-approval",
                "interruptId": "approval_call_c",
                "toolName": "deleteFile",
                "toolCallId": "call_c",
                "originalArgs": {
                  "path": "a"
                },
                "inputSchemaHash": "sha256:c3e75a7d4e4bd6911fa21e7a3dfd29a13253847806e2f840a20e474afaa80517",
                "approvalSchemaHash": "sha256:22f76d9a1c618a3cfaa891208a14f6e5e6ab1be4ff1c38cc8a8cd1e8fd0c0e4e",
                "responseSchemaHash": "sha256:aaa33c4437417e86b31cbe6fd1a8fb88dd4e2962168e91339b80102b72070beb",
                "interruptedRunId": "run-1",
                "generation": 0
              }
            },
            "subagentRunId": "subagent-1"
          }
        ]
      },
      "timestamp": 1
    }
  ],
  [
    {
      "type": "RUN_STARTED",
      "threadId": "t",
      "runId": "run-2",
      "timestamp": 1
    },
    {
      "type": "SUBAGENT_STARTED",
      "subagentRunId": "subagent-1",
      "name": "cleaner",
      "description": "Deletes files",
      "timestamp": 1,
      "metadata": {
        "tanstack": {
          "subagentPlan": {
            "steps": [
              {
                "names": [
                  "cleaner"
                ]
              }
            ]
          }
        }
      },
      "subagentPlan": {
        "steps": [
          {
            "names": [
              "cleaner"
            ]
          }
        ]
      }
    },
    {
      "type": "TOOL_CALL_RESULT",
      "timestamp": 1,
      "messageId": "result-1",
      "toolCallId": "call_c",
      "content": "{\"deleted\":true}",
      "role": "tool",
      "subagentRunId": "subagent-1"
    },
    {
      "type": "TEXT_MESSAGE_START",
      "messageId": "done",
      "role": "assistant",
      "timestamp": 1,
      "metadata": {
        "tanstack": {
          "source": {
            "provider": "scripted",
            "api": "text",
            "model": "test-model"
          }
        }
      },
      "subagentRunId": "subagent-1",
      "source": {
        "provider": "scripted",
        "api": "text",
        "model": "test-model"
      }
    },
    {
      "type": "TEXT_MESSAGE_CONTENT",
      "messageId": "done",
      "delta": "Deleted a",
      "timestamp": 1,
      "metadata": {
        "tanstack": {
          "source": {
            "provider": "scripted",
            "api": "text",
            "model": "test-model"
          }
        }
      },
      "subagentRunId": "subagent-1",
      "source": {
        "provider": "scripted",
        "api": "text",
        "model": "test-model"
      }
    },
    {
      "type": "TEXT_MESSAGE_END",
      "messageId": "done",
      "timestamp": 1,
      "metadata": {
        "tanstack": {
          "source": {
            "provider": "scripted",
            "api": "text",
            "model": "test-model"
          }
        }
      },
      "subagentRunId": "subagent-1",
      "source": {
        "provider": "scripted",
        "api": "text",
        "model": "test-model"
      }
    },
    {
      "type": "SUBAGENT_FINISHED",
      "subagentRunId": "subagent-1",
      "timestamp": 1
    },
    {
      "type": "RUN_FINISHED",
      "threadId": "t",
      "runId": "run-2",
      "timestamp": 1
    }
  ]
]
''';
