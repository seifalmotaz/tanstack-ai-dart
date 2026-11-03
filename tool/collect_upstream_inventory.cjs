// Collect executed case identities and explicit source exports for review.
// npm install --prefix .dart_tool/toolchain typescript@5.9.3
// node tool/collect_upstream_inventory.cjs <upstream-root> <vitest-report> [baseline-inventory]
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {execFileSync} = require('node:child_process');

function caseSourceBodies(ts, code) {
  const source = ts.createSourceFile('suite.ts', code, ts.ScriptTarget.Latest, true);
  if (source.parseDiagnostics.length) throw Error('Invalid TypeScript test source');
  const found = new Map();
  function visit(node, groups) {
    if (ts.isCallExpression(node)) {
      let callee = node.expression;
      if (ts.isPropertyAccessExpression(callee) && ['skip', 'only', 'todo'].includes(callee.name.text)) callee = callee.expression;
      if (ts.isIdentifier(callee) && ['describe', 'it', 'test'].includes(callee.text)) {
        const [title, callback] = node.arguments;
        if (title && ts.isStringLiteralLike(title) && callback && (ts.isArrowFunction(callback) || ts.isFunctionExpression(callback))) {
          const names = [...groups, title.text];
          if (callee.text === 'describe') {
            ts.forEachChild(callback.body, child => visit(child, names));
          } else {
            const name = names.join(' ');
            found.set(name, found.has(name) ? null : callback.body.getText(source));
          }
          return;
        }
      }
    }
    ts.forEachChild(node, child => visit(child, groups));
  }
  visit(source, []);
  return found;
}

function collect(upstream, report, baseline) {
  const ts = require('../.dart_tool/toolchain/node_modules/typescript');
  const paths = ['ai-client', 'ai', 'ai-event-client', 'ai-utils'].flatMap(name =>
    [`packages/${name}/src`, `packages/${name}/tests`, `packages/${name}/package.json`]);
  const dirty = execFileSync('git', ['-C', upstream, 'status', '--porcelain', '--untracked-files=all', '--', ...paths], {encoding: 'utf8'});
  if (dirty.trim()) throw Error('Upstream source or tests differ from HEAD');
  const client = path.join(upstream, 'packages/ai-client');
  const reportBytes = fs.readFileSync(report);
  const result = JSON.parse(reportBytes);
  const tests = result.testResults.flatMap(file => file.assertionResults.map(test => ({
    file: path.basename(file.name), name: test.fullName, title: test.title, status: test.status,
  })));
  if (tests.length !== result.numTotalTests) throw Error('Report count does not match assertions');
  const key = t => `${t.file}\0${t.name}`;
  if (new Set(tests.map(key)).size !== tests.length) throw Error('Duplicate test identity');
  const previous = baseline.files.flatMap(file => file.tests.map(test => ({file: file.file, name: test.name})));
  const before = new Set(previous.map(key));
  const after = new Set(tests.map(key));
  const changedFiles = new Set(execFileSync('git', ['-C', upstream, 'diff', '--name-only', baseline.commit, 'HEAD', '--', 'packages/ai-client/tests'], {encoding: 'utf8'})
    .split('\n').filter(Boolean).map(file => path.basename(file)));
  const sourceReview = {changed: [], unchanged: [], unresolved: []};
  for (const file of changedFiles) {
    const relative = `packages/ai-client/tests/${file}`;
    let previousSource, currentSource;
    try {
      previousSource = execFileSync('git', ['-C', upstream, 'show', `${baseline.commit}:${relative}`], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore']});
      currentSource = fs.readFileSync(path.join(upstream, relative), 'utf8');
    } catch (_) { continue; }
    const oldCases = caseSourceBodies(ts, previousSource);
    const newCases = caseSourceBodies(ts, currentSource);
    for (const item of tests.filter(t => t.file === file && before.has(key(t)))) {
      const oldBody = oldCases.get(item.name), newBody = newCases.get(item.name);
      const status = oldBody == null || newBody == null ? 'unresolved' : oldBody === newBody ? 'unchanged' : 'changed';
      sourceReview[status].push({file, name: item.name});
    }
  }
  const surfaces = {};
  for (const surface of ['index', 'byok', 'ui', 'devtools']) {
    const filename = path.join(client, 'src', `${surface}.ts`);
    const source = ts.createSourceFile(filename, fs.readFileSync(filename, 'utf8'), ts.ScriptTarget.Latest, true);
    if (source.parseDiagnostics.length) throw Error(`Invalid TypeScript source: ${filename}`);
    surfaces[surface] = [];
    for (const node of source.statements) {
      if (node.modifiers?.some(m => m.kind === ts.SyntaxKind.ExportKeyword)) {
        if (node.modifiers.some(m => m.kind === ts.SyntaxKind.DefaultKeyword)) throw Error(`Unsupported default export in ${filename}`);
        if (!node.name) throw Error(`Unsupported exported declaration in ${filename}`);
        surfaces[surface].push({
          name: node.name.text, sourceName: node.name.text,
          typeOnly: ts.isInterfaceDeclaration(node) || ts.isTypeAliasDeclaration(node),
          source: `./${surface}`,
        });
      }
      if (!ts.isExportDeclaration(node)) continue;
      if (!node.exportClause || !ts.isNamedExports(node.exportClause)) {
        throw Error(`Unsupported export form in ${filename}: ${node.getText(source)}`);
      }
      for (const e of node.exportClause.elements) surfaces[surface].push({
        name: e.name.text, sourceName: (e.propertyName || e.name).text,
        typeOnly: node.isTypeOnly || e.isTypeOnly,
        source: node.moduleSpecifier?.text ?? null,
      });
    }
    if (new Set(surfaces[surface].map(e => e.name)).size !== surfaces[surface].length) {
      throw Error(`Duplicate export in ${filename}`);
    }
  }
  return {
    version: JSON.parse(fs.readFileSync(path.join(client, 'package.json'), 'utf8')).version,
    coreVersion: JSON.parse(fs.readFileSync(path.join(upstream, 'packages/ai/package.json'), 'utf8')).version,
    commit: execFileSync('git', ['-C', upstream, 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim(),
    reportSha256: crypto.createHash('sha256').update(reportBytes).digest('hex'),
    reportSuccess: result.success,
    failedSuites: result.numFailedTestSuites,
    result: {total: tests.length, passed: tests.filter(t => t.status === 'passed').length,
      failed: tests.filter(t => t.status === 'failed').length,
      other: tests.filter(t => !['passed', 'failed'].includes(t.status)).length},
    retained: tests.filter(t => before.has(key(t))).length,
    retainedInChangedFiles: tests.filter(t => before.has(key(t)) && changedFiles.has(t.file)),
    sourceReview,
    added: tests.filter(t => !before.has(key(t))),
    removed: previous.filter(t => !after.has(key(t))),
    surfaces,
    tests,
  };
}
if (require.main === module) {
  const [upstream, report, baselinePath] = process.argv.slice(2);
  if (!upstream || !report) throw Error('Expected upstream root and Vitest JSON report');
  const baseline = JSON.parse(fs.readFileSync(baselinePath ?? path.join(__dirname, 'upstream_tests.json'), 'utf8'));
  process.stdout.write(JSON.stringify(collect(path.resolve(upstream), path.resolve(report), baseline), null, 2) + '\n');
}
module.exports = {collect, caseSourceBodies};
