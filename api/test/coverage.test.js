/**
 * The Worker and the recorder each compute coverage in their own language.
 * If they disagree, the API would show a day as complete that the alerter
 * flagged (or the reverse), so these run the SAME fixtures as
 * tests/test_coverage.py and the two must match.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const src = readFileSync(
  path.join(path.dirname(fileURLToPath(import.meta.url)), "../src/index.js"), "utf8");

// pull the pure functions out of the module without its Worker export
const body = src.slice(0, src.indexOf("export default"));
const mod = await import("data:text/javascript," + encodeURIComponent(
  body + "\nexport { coverage, NAME_RE };"));
const { coverage } = mod;

const FULL = 7200000;
const o = (h, m = 0, s = 0, size = FULL) => ({
  key: `qa/kzmp/2026/09/30/kzmp_2026-09-30_${String(h).padStart(2,"0")}${String(m).padStart(2,"0")}${String(s).padStart(2,"0")}_CT.mp3`,
  size,
});
const day = "2026-09-30", st = "kzmp";
const range = (a, b) => Array.from({ length: b - a }, (_, i) => o(a + i));

const cases = [
  ["perfect 18-hour day", range(6, 24), true, 18],
  ["total failure", [], false, 0],
  ["died at 15:00", range(6, 15), false, 9],
  ["one short hour", [...range(6,24).filter((_,i)=>i+6!==9), o(9,0,0,Math.floor(FULL*0.33))], false, 17],
  ["mid-hour restart, two partials",
    [...range(6,24).filter((_,i)=>i+6!==14), o(14,0,0,Math.floor(FULL*0.4)), o(14,24,0,Math.floor(FULL*0.6))], true, 18],
  ["UNALIGNED segments spanning hours",
    [o(6,0,0,FULL*1.5), o(7,30,0,FULL*1.5), o(9,0,0,FULL*1.5), o(10,30,0,FULL*1.5), ...range(12,24)], true, 18],
  ["segment straddling midnight clamped", [...range(6,23), o(23,0,0,FULL*2)], true, 18],
  ["overlapping duplicates not double-counted", [...range(6,24), o(8)], true, 18],
  ["other station ignored", [...range(6,24), {key:"qa/kzmp/2026/09/30/other_2026-09-30_060000_CT.mp3", size:FULL}], true, 18],
  ["other day ignored", [...range(6,24), {key:"qa/kzmp/2026/09/30/kzmp_2026-09-29_060000_CT.mp3", size:FULL}], true, 18],
  ["malformed name ignored", [...range(6,24), {key:"qa/kzmp/2026/09/30/garbage.mp3", size:FULL}], true, 18],
];

let fails = 0;
for (const [name, objs, wantComplete, wantOk] of cases) {
  const r = coverage(objs, st, day);
  const ok = r.complete === wantComplete && r.hours_ok === wantOk;
  if (!ok) fails++;
  console.log(`  ${ok ? "PASS" : "FAIL"}  ${name.padEnd(42)} complete=${r.complete} ok=${r.hours_ok}/${r.hours_total}`);
}
console.log(`\n${cases.length - fails}/${cases.length} passed`);
process.exit(fails ? 1 : 0);
