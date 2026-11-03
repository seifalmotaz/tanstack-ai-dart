const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const {collect, caseSourceBodies} = require('./collect_upstream_inventory.cjs');
const ts = require('../.dart_tool/toolchain/node_modules/typescript');
const bodies = caseSourceBodies(ts, "describe('group', () => { it('one', () => { expect(1).toBe(1) }); it.each([1])('dynamic', () => {}) })");
assert.match(bodies.get('group one'), /expect\(1\)/);
assert.equal(bodies.has('group dynamic'), false);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'upstream-inventory-'));
try {
  const client = path.join(root, 'packages/ai-client');
  fs.mkdirSync(path.join(client, 'src'), {recursive: true});
  fs.mkdirSync(path.join(root, 'packages/ai'), {recursive: true});
  fs.writeFileSync(path.join(root, 'packages/ai/package.json'), JSON.stringify({version: '1.0.1'}));
  execFileSync('git', ['init', '-q', root]);
  function commit() {
    execFileSync('git', ['-C', root, 'add', 'packages']);
    execFileSync('git', ['-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-q', '--allow-empty', '-m', 'fixture']);
  }
  fs.writeFileSync(path.join(client, 'package.json'), JSON.stringify({version: '1.0.1'}));
  fs.writeFileSync(path.join(client, 'src/index.ts'), "export { old as renamed } from './x'\nexport type { Shape } from './x'\n");
  fs.writeFileSync(path.join(client, 'src/byok.ts'), "export { key } from './x'\n");
  fs.writeFileSync(path.join(client, 'src/ui.ts'), "export type { View } from './x'\n");
  fs.writeFileSync(path.join(client, 'src/devtools.ts'), 'export interface State {}\nexport class Bridge {}\n');
  commit();
  const baseline = {commit: execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim(), files: [{file: 'test.ts', tests: [{name: 'retained'}, {name: 'removed'}]}]};
  const report = path.join(root, 'report.json');
  fs.writeFileSync(report, JSON.stringify({numTotalTests: 2, testResults: [{name: '/suite/test.ts', assertionResults: [
    {fullName: 'retained', title: 'retained', status: 'passed'},
    {fullName: 'new', title: 'new', status: 'failed'},
  ]}]}));
  const result = collect(root, report, baseline);
  assert.deepEqual(result.result, {total: 2, passed: 1, failed: 1, other: 0});
  assert.equal(result.retained, 1);
  assert.equal(result.added[0].name, 'new');
  assert.equal(result.removed[0].name, 'removed');
  assert.deepEqual(result.surfaces.index[0], {name: 'renamed', sourceName: 'old', typeOnly: false, source: './x'});
  assert.equal(result.surfaces.index[1].typeOnly, true);
  assert.equal(result.surfaces.devtools[0].typeOnly, true);
  assert.equal(result.surfaces.devtools[1].typeOnly, false);
  fs.writeFileSync(path.join(client, 'src/ui.ts'), 'export type { Broken ');
  assert.throws(() => collect(root, report, baseline), /differ from HEAD/);
  commit();
  assert.throws(() => collect(root, report, baseline), /Invalid TypeScript/);
  fs.writeFileSync(path.join(client, 'src/ui.ts'), "export { x, x } from './x'\n");
  commit();
  assert.throws(() => collect(root, report, baseline), /Duplicate export/);
  fs.writeFileSync(path.join(client, 'src/ui.ts'), 'export default class Example {}');
  commit();
  assert.throws(() => collect(root, report, baseline), /default export/);
  fs.writeFileSync(report, JSON.stringify({numTotalTests: 3, testResults: []}));
  assert.throws(() => collect(root, report, baseline), /count/);
  console.log('inventory collector self-test passed');
} finally { fs.rmSync(root, {recursive: true, force: true}); }
