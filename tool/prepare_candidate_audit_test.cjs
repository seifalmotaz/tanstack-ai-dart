// The candidate audit must never overwrite the supported repository manifests.
const {spawnSync} = require('node:child_process');
const assert = require('node:assert/strict');
for (const output of ['.', '.dart_tool', '..']) {
  const result = spawnSync(process.execPath,
    ['tool/prepare_candidate_audit.cjs', '.dart_tool/candidate-inventory.json', output],
    {encoding: 'utf8'});
  assert.notEqual(result.status, 0, `accepted unsafe output ${output}`);
  assert.match(result.stderr, /output must be a child of \.dart_tool/);
}
console.log('candidate audit output guard passed');
