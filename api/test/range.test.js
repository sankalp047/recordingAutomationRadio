/** Range queries across a multi-year archive: prefix selection, date filtering
 *  at boundaries, and the R2 call count staying sane. */
import worker from "../src/index.js";

const FULL = 7200000;
const store = new Map();
function seed(station, date, hours = [...Array(18)].map((_, i) => i + 6)) {
  const [y, mo, d] = date.split("-");
  for (const h of hours) {
    store.set(`qa/${station}/${y}/${mo}/${d}/${station}_${date}_${String(h).padStart(2,"0")}0000_CT.mp3`,
      { size: FULL, uploaded: new Date(`${date}T12:00:00Z`) });
  }
}
// three years of one station, sampled; plus dense coverage in one month
for (const d of ["2024-01-15","2024-06-15","2025-01-15","2025-06-15","2026-01-15","2026-09-28","2026-09-29","2026-09-30"])
  seed("funasia", d);
for (let i = 1; i <= 28; i++) seed("sangam", `2026-09-${String(i).padStart(2,"0")}`);

let listCalls = 0;
const ARCHIVE = {
  async list({ prefix, cursor, limit = 1000 }) {
    listCalls++;
    const all = [...store.entries()].filter(([k]) => k.startsWith(prefix))
      .map(([key, v]) => ({ key, size: v.size, uploaded: v.uploaded }))
      .sort((a, b) => (a.key < b.key ? -1 : 1));
    const start = cursor ? parseInt(cursor, 10) : 0;
    const page = all.slice(start, start + limit);
    const end = start + page.length;
    return { objects: page, truncated: end < all.length, cursor: String(end) };
  },
  async head() { return { size: FULL }; },
  async get() { return { body: Buffer.alloc(8), size: FULL }; },
};
const env = { ARCHIVE, STATIONS: "sangam,funasia", API_TOKEN: "t" };
const AUTH = { Authorization: "Bearer t" };
const call = (p) => worker.fetch(new Request("https://api.test" + p, { headers: AUTH }), env);

let fails = 0;
async function t(name, fn) {
  listCalls = 0;
  try { await fn(); console.log(`  PASS  ${name.padEnd(46)} (${listCalls} R2 list calls)`); }
  catch (e) { fails++; console.log(`  FAIL  ${name}\n          ${e.message}`); }
}
const eq = (a,b,m) => { if (JSON.stringify(a)!==JSON.stringify(b)) throw new Error(`${m||""} got ${JSON.stringify(a)} want ${JSON.stringify(b)}`); };
const ok = (c,m) => { if (!c) throw new Error(m); };

await t("single day", async () => {
  const b = await (await call("/recordings?station=funasia&date=2026-09-30")).json();
  eq(b.count, 18);
});
await t("3-day range filters neighbours out", async () => {
  const b = await (await call("/recordings?station=funasia&from=2026-09-29&to=2026-09-30")).json();
  eq(b.count, 36);
  ok(b.recordings.every(r => r.date >= "2026-09-29" && r.date <= "2026-09-30"), "leaked a date");
});
await t("full month, dense (28 days x 18h)", async () => {
  const b = await (await call("/recordings?station=sangam&from=2026-09-01&to=2026-09-30")).json();
  eq(b.count, 504);
  ok(listCalls <= 2, `too many list calls: ${listCalls}`);
});
await t("full year spanning months (one year prefix)", async () => {
  // funasia is seeded on 4 days in 2026: 01-15, 09-28, 09-29, 09-30
  const b = await (await call("/recordings?station=funasia&from=2026-01-01&to=2026-12-31")).json();
  eq(b.count, 72);
  ok(b.recordings.every(r => r.date.startsWith("2026")), "leaked another year");
  ok(listCalls <= 2, `year query should be ~1 prefix, got ${listCalls}`);
});
await t("year query excludes adjacent years", async () => {
  const b = await (await call("/recordings?station=funasia&from=2025-01-01&to=2025-12-31")).json();
  eq(b.count, 36, "2025 has 2 seeded days");
  ok(b.recordings.every(r => r.date.startsWith("2025")), "leaked another year");
});
await t("range >366 days rejected with a clear message", async () => {
  const r = await call("/recordings?station=funasia&from=2024-01-01&to=2026-12-31");
  eq(r.status, 400);
  const b = await r.json();
  ok(/range too large/.test(b.error), `got ${b.error}`);
  ok(/1096 days/.test(b.detail), `detail should name the size, got: ${b.detail}`);
});
await t("exactly 366 days allowed", async () => {
  const r = await call("/recordings?station=funasia&from=2025-01-01&to=2026-01-01");
  eq(r.status, 200);
});
await t("from > to rejected", async () => {
  eq((await call("/recordings?station=funasia&from=2026-09-30&to=2026-09-01")).status, 400);
});
await t("boundary: range ending on a seeded day is inclusive", async () => {
  const b = await (await call("/recordings?station=sangam&from=2026-09-01&to=2026-09-01")).json();
  eq(b.count, 18);
});
await t("pagination past 1000 objects", async () => {
  const b = await (await call("/recordings?station=sangam&from=2026-09-01&to=2026-09-28&limit=5000")).json();
  eq(b.count, 504);
  eq(b.truncated, false);
});
await t("coverage still works on an old date", async () => {
  const b = await (await call("/coverage?date=2024-01-15&station=funasia")).json();
  eq(b.stations[0].complete, true); eq(b.stations[0].hours_ok, 18);
});

console.log(`\n${fails ? fails + " FAILED" : "all passed"}`);
process.exit(fails ? 1 : 0);
