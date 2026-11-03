// Build an ignored capture probe from the pinned upstream integration test.
// Run from the Dart package root; then run Vitest using the adjacent config.
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const root = '.dart_tool/upstream-ai';
const head = execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim();
if (head !== 'a7eb58459ebd528bbcc4166cc68377b777989462') throw Error('Unexpected upstream revision');
let source = fs.readFileSync(path.join(root, 'packages/ai-client/tests/chat-client-subagent-interrupts.test.ts'), 'utf8');
function replaceOnce(from, to) {
  if (source.split(from).length !== 2) throw Error(`Unexpected upstream fixture: ${from.slice(0, 50)}`);
  source = source.replace(from, to);
}
source = "import {writeFileSync} from 'node:fs'\n" + source;
replaceOnce("from 'zod'", "from '../packages/ai-client/node_modules/zod'");
replaceOnce("from '../src/chat-client'", "from '../packages/ai-client/src/chat-client'");
replaceOnce("from '../src/connection-adapters'", "from '../packages/ai-client/src/connection-adapters'");
replaceOnce('    const connection: ConnectConnectionAdapter = {\n      connect: (messages, _data, _signal, runContext) =>\n        chat({',
  '    const captured: Array<Array<StreamChunk>> = []\n    const connection: ConnectConnectionAdapter = {\n      async *connect(messages, _data, _signal, runContext) {\n        const batch: Array<StreamChunk> = []\n        captured.push(batch)\n        const stream = chat({');
replaceOnce('          subagents: { agents: [cleaner], router: () => \'cleaner\' },\n        }),\n    }',
  '          subagents: { agents: [cleaner], router: () => \'cleaner\' },\n        })\n        for await (const chunk of stream) { batch.push(chunk); yield chunk }\n      },\n    }');
replaceOnce("    expect(parts).toContainEqual({ type: 'text', content: 'Deleted a' })", "    expect(parts).toContainEqual({ type: 'text', content: 'Deleted a' })\n    writeFileSync('.dart_tool/subagent-chunks.json', JSON.stringify(captured, null, 2))");
fs.writeFileSync(path.join(root, '.dart_tool/capture-subagent.test.ts'), source);
