// Classify retained literal test bodies whose only AST change is an explicit
// threadId option on a client constructor. Other edits remain for manual review.
// Usage: node tool/review_upstream_mechanical.cjs <upstream-root> <candidate.json> [baseline-inventory]
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const ts = require('../.dart_tool/toolchain/node_modules/typescript');
const {caseSourceBodies} = require('./collect_upstream_inventory.cjs');
const [root, candidatePath, baselinePath] = process.argv.slice(2);
if (!root || !candidatePath) throw Error('Expected upstream root and candidate inventory');
const candidate = JSON.parse(fs.readFileSync(candidatePath, 'utf8'));
const baseline = JSON.parse(fs.readFileSync(baselinePath ?? 'tool/upstream_tests.json', 'utf8'));
const printer = ts.createPrinter({removeComments: true});
function isClientOptions(node) {
  return (ts.isNewExpression(node) || ts.isCallExpression(node)) && ts.isIdentifier(node.expression) &&
    ['ChatClient', 'GenerationClient', 'VideoGenerationClient', 'createChatClientOptions'].includes(node.expression.text);
}
function normalized(code, removeThreadId, removeRunContext = false) {
  const source = ts.createSourceFile('body.ts', code, ts.ScriptTarget.Latest, true);
  if (source.parseDiagnostics.length) throw Error('Cannot parse test body');
  const result = ts.transform(source, [context => {
    const visit = node => {
      if (removeThreadId && isClientOptions(node) && node.arguments) {
        const args = node.arguments.map(arg => ts.isObjectLiteralExpression(arg)
          ? ts.factory.updateObjectLiteralExpression(arg, arg.properties.filter(property =>
              !(ts.isPropertyAssignment(property) && property.name.getText(source) === 'threadId')))
          : arg);
        node = ts.isNewExpression(node)
          ? ts.factory.updateNewExpression(node, node.expression, node.typeArguments, args)
          : ts.factory.updateCallExpression(node, node.expression, node.typeArguments, args);
      }
      if (removeRunContext && ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression) &&
          ['connect', 'send'].includes(node.expression.name.text) && node.arguments.length === 4 &&
          ts.isIdentifier(node.arguments[3]) && node.arguments[3].text === 'RUN_CONTEXT') {
        const args = [...node.arguments.slice(0, 3)];
        while (args.length > 1 && ts.isIdentifier(args[args.length - 1]) && args[args.length - 1].text === 'undefined') args.pop();
        node = ts.factory.updateCallExpression(node, node.expression, node.typeArguments, args);
      }
      return ts.visitEachChild(node, visit, context);
    };
    return node => ts.visitNode(node, visit);
  }]);
  const text = printer.printFile(result.transformed[0]);
  result.dispose();
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, true, ts.LanguageVariant.Standard, text);
  const tokens = [];
  for (let token = scanner.scan(); token !== ts.SyntaxKind.EndOfFileToken; token = scanner.scan()) tokens.push([token, scanner.getTokenText()]);
  const canonical = tokens.filter((entry, i) => !(entry[1] === ',' &&
    [')', ']', '}'].includes(tokens[i + 1]?.[1]) && tokens[i - 1]?.[1] !== ','));
  return JSON.stringify(canonical);
}
function threadIds(code) {
  const source = ts.createSourceFile('body.ts', code, ts.ScriptTarget.Latest, true);
  const result = [];
  function visit(node) {
    if (isClientOptions(node)) {
      const ids = [];
      for (const arg of node.arguments ?? []) if (ts.isObjectLiteralExpression(arg)) {
        for (const property of arg.properties) if (ts.isPropertyAssignment(property) && property.name.getText(source) === 'threadId') {
          ids.push(property.initializer.getText(source));
        }
      }
      result.push(ids);
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
  return result;
}
function onlyAddedIds(old, current) {
  const before = threadIds(old), after = threadIds(current);
  if (before.length !== after.length) return false;
  let added = false;
  for (let i = 0; i < before.length; i++) {
    const next = [...after[i]];
    for (const id of before[i]) {
      const index = next.indexOf(id);
      if (index < 0) return false;
      next.splice(index, 1);
    }
    if (next.length) added = true;
  }
  return added && normalized(old, true) === normalized(current, true);
}
function onlyAddedRunContext(old, current) {
  if (!current.includes('RUN_CONTEXT')) return false;
  const before = threadIds(old), after = threadIds(current);
  if (before.length !== after.length) return false;
  for (let i = 0; i < before.length; i++) {
    const next = [...after[i]];
    for (const id of before[i]) {
      const index = next.indexOf(id);
      if (index < 0) return false;
      next.splice(index, 1);
    }
  }
  return normalized(old, true) === normalized(current, true, true);
}
const byFile = new Map();
for (const item of candidate.sourceReview.changed) {
  if (!byFile.has(item.file)) {
    const relative = `packages/ai-client/tests/${item.file}`;
    const old = execFileSync('git', ['-C', root, 'show', `${baseline.commit}:${relative}`], {encoding: 'utf8'});
    const current = fs.readFileSync(path.join(root, relative), 'utf8');
    byFile.set(item.file, [caseSourceBodies(ts, old), caseSourceBodies(ts, current)]);
  }
}
const mechanical = [], runContext = [], remaining = [];
for (const item of candidate.sourceReview.changed) {
  const [old, current] = byFile.get(item.file);
  const a = old.get(item.name), b = current.get(item.name);
  (a && b && onlyAddedIds(a, b) ? mechanical : a && b && onlyAddedRunContext(a, b) ? runContext : remaining).push(item);

}
process.stdout.write(JSON.stringify({baseline: baseline.commit, candidate: candidate.commit, mechanical, runContext, remaining}, null, 2) + '\n');
