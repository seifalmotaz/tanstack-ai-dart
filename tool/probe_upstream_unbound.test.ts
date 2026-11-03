import {expect, it} from 'vitest'
import {EventType, toolDefinition} from '@tanstack/ai/client'
import {z} from '../packages/ai-client/node_modules/zod'
import {ChatClient} from '../packages/ai-client/src/chat-client'

it('upstream executes a client-tool interrupt without a binding', async () => {
  let executions = 0
  const lookup = toolDefinition({name: 'lookup', description: 'Look up', inputSchema: z.object({}), outputSchema: z.number()})
    .client(async () => { executions++; return 1 })
  const client = new ChatClient({threadId: 'thread-1', tools: [lookup], connection: {
    async *connect(_messages, _data, _signal, context) {
      const runId = context!.runId
      const threadId = context!.threadId
      yield {type: EventType.RUN_STARTED, runId, threadId, timestamp: Date.now()}
      yield {type: EventType.TOOL_CALL_START, toolCallId: 'tc1', toolCallName: 'lookup', timestamp: Date.now()}
      yield {type: EventType.TOOL_CALL_ARGS, toolCallId: 'tc1', delta: '{}', timestamp: Date.now()}
      yield {type: EventType.TOOL_CALL_END, toolCallId: 'tc1', timestamp: Date.now()}
      yield {type: EventType.RUN_FINISHED, runId, threadId, timestamp: Date.now(), outcome: {type: 'interrupt', interrupts: [{id: 'unbound', toolCallId: 'tc1', reason: 'client_tool_input', metadata: {kind: 'client_tool', toolName: 'lookup', input: {}}}]}}
    },
  }})
  await client.sendMessage('hi')
  expect(executions).toBe(1)
  expect(client.getInterrupts()[0]?.kind).toBe('unbound')
})
