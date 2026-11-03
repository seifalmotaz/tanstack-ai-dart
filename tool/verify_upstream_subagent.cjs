// Normalize an upstream subagent capture and compare it to the Dart fixture.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const input = process.argv[2];
if (!input) throw Error('Expected subagent capture JSON');
const batches = JSON.parse(fs.readFileSync(input, 'utf8'));
assert.equal(batches.length, 2);
const runIds = batches.map(batch => batch.find(chunk => chunk.type === 'RUN_STARTED').runId);
const subagentId = batches[0].find(chunk => chunk.type === 'SUBAGENT_STARTED').subagentRunId;
const resultId = batches[1].find(chunk => chunk.type === 'TOOL_CALL_RESULT').messageId;
function normalize(value, key) {
  if (key === 'timestamp') return 1;
  if (typeof value === 'string') {
    if (value === runIds[0]) return 'run-1';
    if (value === runIds[1]) return 'run-2';
    if (value === subagentId) return 'subagent-1';
    if (value === resultId) return 'result-1';
    return value;
  }
  if (Array.isArray(value)) return value.map(item => normalize(item));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, normalize(v, k)]));
  return value;
}
const normalized = normalize(batches);
const dart = "// Captured from pinned upstream 1.0.1; see tool/capture_upstream_subagent.cjs.\nconst upstreamSubagentFixture = r'''\n" + JSON.stringify(normalized, null, 2) + "\n''';\n";
if (process.argv.includes('--write')) fs.writeFileSync('test/processing/subagent_upstream_fixture.dart', dart);
else assert.equal(fs.readFileSync('test/processing/subagent_upstream_fixture.dart', 'utf8'), dart);
console.log('upstream subagent fixture matches normalized capture');
