// Compare a captured official stream with the checked-in normalized fixture.
// Run the capture via the instructions in doc/maintainers/upstream-updates.md.
const fs = require('node:fs');
function normalize(value, key = '') {
  if (Array.isArray(value)) return value.map(item => normalize(item));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, normalize(v, k)]));
  if (key === 'timestamp') return 1;
  if (key === 'createdAt') return '2026-01-01T00:00:00.000Z';
  return typeof value === 'string' ? value.replace(/chat-\d+-[a-z0-9]+/g, 'chat-fixed').replace(/msg-\d+-[a-z0-9]+/g, 'msg-fixed') : value;
}
const actual = normalize(JSON.parse(fs.readFileSync(process.argv[2], 'utf8')));
const fixture = fs.readFileSync('test/processing/mixed_upstream_fixture.dart', 'utf8').match(/r'''([\s\S]*?)'''/);
if (!fixture || JSON.stringify(actual) !== JSON.stringify(JSON.parse(fixture[1]))) throw Error('Captured upstream stream differs from fixture');
console.log('Normalized upstream mixed stream matches fixture');
