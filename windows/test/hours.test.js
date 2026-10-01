// Each hour row must own only the recordings that START in that hour.
// Regression test: a full hour's duration is derived from object size and
// measures slightly over 3600s, so overlap-based matching put one recording
// in two rows - two "Playing" highlights, and "Not recorded" shown beside a
// neighbour's duration.
const assert = require('node:assert');

function segmentsAt(recordings, st, hour) {
  return recordings
    .filter((r) => r.station === st && Number(r.start_local.slice(0, 2)) === hour)
    .sort((a, b) => a.start_local.localeCompare(b.start_local));
}

const rec = (h, m, dur, id) => ({
  id: id || `s-${h}-${m}`, station: 'sangam',
  start_local: `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:00`,
  duration_seconds: dur,
});

let fails = 0;
const t = (name, fn) => {
  try { fn(); console.log(`  PASS  ${name}`); }
  catch (e) { fails++; console.log(`  FAIL  ${name}\n          ${e.message}`); }
};

t('a 3600.2s hour does not leak into the next row', () => {
  const recs = [rec(15, 0, 3600.2, 'three-pm')];
  assert.equal(segmentsAt(recs, 'sangam', 15).length, 1, '3 PM owns it');
  assert.equal(segmentsAt(recs, 'sangam', 16).length, 0, '4 PM must not');
});

t('only one row can be playing', () => {
  const recs = [rec(15, 0, 3600.2, 'three-pm'), rec(16, 0, 3600.4, 'four-pm')];
  const playing = 'three-pm';
  const lit = [15, 16, 17].filter((h) =>
    segmentsAt(recs, 'sangam', h).some((s) => s.id === playing));
  assert.deepEqual(lit, [15], `highlighted hours: ${lit}`);
});

t('an empty hour shows no duration from a neighbour', () => {
  const recs = [rec(18, 0, 3600.3, 'six-pm')];
  assert.equal(segmentsAt(recs, 'sangam', 19).length, 0,
    '7 PM must be empty, not borrow 6 PM');
});

t('a mid-hour restart keeps both pieces in their own hour', () => {
  const recs = [rec(14, 26, 2014, 'a'), rec(15, 0, 3600.2, 'b'), rec(16, 23, 1200, 'c')];
  assert.equal(segmentsAt(recs, 'sangam', 14).length, 1);
  assert.equal(segmentsAt(recs, 'sangam', 15).length, 1);
  assert.equal(segmentsAt(recs, 'sangam', 16).length, 1);
});

t('two restarts inside one hour both belong to it', () => {
  const recs = [rec(16, 0, 1400, 'a'), rec(16, 24, 2100, 'b')];
  assert.equal(segmentsAt(recs, 'sangam', 16).length, 2, 'saved in 2 pieces');
  assert.equal(segmentsAt(recs, 'sangam', 17).length, 0);
});

t('other stations are never mixed in', () => {
  const recs = [rec(15, 0, 3600, 'a'), { ...rec(15, 0, 3600, 'b'), station: 'funasia' }];
  assert.equal(segmentsAt(recs, 'sangam', 15).length, 1);
});

console.log(`\n${fails ? fails + ' FAILED' : 'all passed'}`);
process.exit(fails ? 1 : 0);
