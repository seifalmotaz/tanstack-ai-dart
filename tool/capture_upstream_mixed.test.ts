import {it} from 'vitest'
import {writeFileSync} from 'node:fs'
import {chat} from '../packages/ai/src/activities/chat/index'
import {ev, clientTool, collectChunks, createMockAdapter, serverTool} from '../packages/ai/tests/test-utils'
it('captures official mixed stream', async () => {
 const {adapter}=createMockAdapter({iterations:[[ev.runStarted(),ev.toolStart('call_server','searchTools'),ev.toolArgs('call_server','{"query":"hello"}'),ev.toolStart('call_client','showNotification'),ev.toolArgs('call_client','{"message":"done"}'),ev.runFinished('tool_calls')]]})
 const result=await collectChunks(chat({threadId:'thread-1',adapter,messages:[{role:'user',content:'Search and notify'}],tools:[serverTool('searchTools',()=>({results:['a','b']})),clientTool('showNotification')]}) as AsyncIterable<any>)
 writeFileSync('.dart_tool/mixed-chunks.json',JSON.stringify(result,null,2))
})
