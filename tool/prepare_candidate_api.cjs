// Build review-only API inventories on stdout from the executed collector and
// explicit candidate records. This never writes supported package manifests.
const fs = require('node:fs');
const [candidatePath] = process.argv.slice(2);
if (!candidatePath) throw Error('Expected candidate inventory');
const candidate = JSON.parse(fs.readFileSync(candidatePath, 'utf8'));
const baseline = JSON.parse(fs.readFileSync('tool/upstream_api_compatibility.json', 'utf8'));
const review = JSON.parse(fs.readFileSync('tool/upstream_api_candidate_review.json', 'utf8'));
if (review.candidate !== candidate.commit) throw Error('API review pin mismatch');
const surfaces = {};
for (const [name, declarations] of Object.entries(candidate.surfaces)) {
  const old = baseline.surfaces[name]?.records ?? [];
  const added = name === 'devtools' ? review.devtools : name === 'index' ? review.indexAdded : [];
  const records = declarations.map(declaration => {
    const retained = old.filter(item => item.name === declaration.name);
    const matches = retained.length ? retained : added.filter(item => item.name === declaration.name);
    if (matches.length !== 1) throw Error(`Expected one API record for ${name}:${declaration.name}`);
    const override = name === 'index' || name === 'byok' ? review.retainedOverrides?.[declaration.name] : null;
    return {...matches[0], ...override, source: declaration.source};
  });
  surfaces[name] = {total: records.length, records};
}
const compatibility = {
  ...baseline,
  dartApiRevision: '0.4.0',
  target: {aiClient: candidate.version, ai: candidate.coreVersion, commit: candidate.commit},
  publicBarrels: {...baseline.publicBarrels, devtools: 'lib/devtools.dart'},
  surfaces,
};
process.stdout.write(JSON.stringify({
  notice: 'Candidate review only; retained records still require assertion and API review.',
  inventory: {version: candidate.version, commit: candidate.commit, surfaces: candidate.surfaces},
  compatibility,
}, null, 2) + '\n');
