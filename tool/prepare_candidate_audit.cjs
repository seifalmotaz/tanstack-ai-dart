// Prepare an isolated parity audit without advancing the supported baseline.
// Usage: node tool/prepare_candidate_audit.cjs candidate-inventory.json output-dir
const fs = require('node:fs');
const path = require('node:path');
const [input, output] = process.argv.slice(2);
if (!input || !output) throw new Error('expected candidate inventory and output directory');
const toolRoot = fs.realpathSync('.dart_tool');
const outputPath = path.resolve(output);
if (!outputPath.startsWith(toolRoot + path.sep)) throw new Error('output must be a child of .dart_tool');
if (fs.existsSync(outputPath)) {
  const actual = fs.realpathSync(outputPath);
  if (!actual.startsWith(toolRoot + path.sep) || !fs.existsSync(path.join(actual, '.candidate-audit-owned'))) {
    throw new Error('existing output is not an owned candidate audit directory');
  }
  fs.rmSync(path.join(actual, 'test'), {recursive: true, force: true});
} else {
  const parent = fs.realpathSync(path.dirname(outputPath));
  if (parent !== toolRoot && !parent.startsWith(toolRoot + path.sep)) {
    throw new Error('output parent resolves outside .dart_tool');
  }
  fs.mkdirSync(outputPath);
  const actual = fs.realpathSync(outputPath);
  if (!actual.startsWith(toolRoot + path.sep)) throw new Error('output resolves outside .dart_tool');
  fs.writeFileSync(path.join(actual, '.candidate-audit-owned'), 'Generated candidate audit; safe to refresh.\n');
}
const inventory = JSON.parse(fs.readFileSync(input, 'utf8'));
if (!inventory.reportSuccess || inventory.failedSuites || inventory.tests.some(test => test.status !== 'passed')) {
  throw new Error('candidate report is not fully passing');
}
const files = new Map();
for (const test of inventory.tests) {
  if (!files.has(test.file)) files.set(test.file, []);
  files.get(test.file).push({name: test.name, title: test.title, baselineStatus: test.status});
}
fs.mkdirSync(path.join(output, 'tool'), {recursive: true});
fs.copyFileSync('tool/parity_audit.dart', path.join(output, 'tool/parity_audit.dart'));
fs.cpSync('test', path.join(output, 'test'), {recursive: true, filter: source => fs.statSync(source).isDirectory() || source.endsWith('mapping.json')});
fs.writeFileSync(path.join(output, 'tool/upstream_tests.json'), JSON.stringify({
  package: '@tanstack/ai-client', version: inventory.version, commit: inventory.commit,
  runtimeTests: inventory.tests.length, baselinePassed: inventory.tests.length,
  files: [...files].sort(([a], [b]) => a.localeCompare(b)).map(([file, tests]) => ({file, tests})),
}, null, 2) + '\n');

// Reviewed candidate cases supplement the old mappings only in this isolated copy.
const reviewed = JSON.parse(fs.readFileSync('tool/upstream_candidate_review.json', 'utf8'));
if (reviewed.candidate !== inventory.commit) throw new Error('candidate review pin mismatch');
const added = new Set(inventory.added.map(test => `${test.file}\0${test.name}`));
const mapped = reviewed.cases.filter(test => added.has(`${test.upstreamFile}\0${test.upstreamName}`)).map(test => ({
  upstreamFile: test.upstreamFile, upstreamName: test.upstreamName, dartFile: test.dartFile,
  dartTestName: test.dartTest, dartAdaptation: test.evidence,
}));
fs.writeFileSync(path.join(output, 'test/candidate_mapping.json'), JSON.stringify({mapped}, null, 2) + '\n');

// Remove only mappings accounted for by the explicit removed-case ledger.
const removed = JSON.parse(fs.readFileSync('tool/upstream_removed_cases.json', 'utf8'));
if (removed.candidate !== inventory.commit) throw new Error('removal ledger pin mismatch');
function prune(node, inheritedFile) {
  if (!node || typeof node !== 'object') return node;
  const file = node.upstreamFile ?? inheritedFile;
  if (Array.isArray(node)) {
    return node.filter(entry => {
      if (!entry || typeof entry !== 'object' || !entry.upstreamName) return true;
      const entryFile = entry.upstreamFile ?? inheritedFile;
      return !removed.cases.some(old => old.file === entryFile &&
        (old.name === entry.upstreamName || old.name.endsWith(` ${entry.upstreamName}`) || entry.upstreamName.endsWith(` ${old.name}`)));
    }).map(entry => prune(entry, inheritedFile));
  }
  for (const [key, value] of Object.entries(node)) node[key] = prune(value, file);
  return node;
}
function pruneMappings(directory) {
  for (const name of fs.readdirSync(directory)) {
    const target = path.join(directory, name);
    if (fs.statSync(target).isDirectory()) pruneMappings(target);
    else if (name.endsWith('mapping.json') && name !== 'candidate_mapping.json') {
      const data = prune(JSON.parse(fs.readFileSync(target, 'utf8')));
      fs.writeFileSync(target, JSON.stringify(data, null, 2) + '\n');
    }
  }
}
pruneMappings(path.join(output, 'test'));
