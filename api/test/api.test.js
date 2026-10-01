/** Exercises the Worker's routing, auth, JSON shapes and Range handling
 *  against a fake R2 binding. */
import worker from "../src/index.js";

const FULL = 7200000;
const store = new Map();
function seed(station, date, hours, size = FULL) {
  for (const h of hours) {
    const f = `${station}_${date}_${String(h).padStart(2,"0")}0000_CT.mp3`;
    const [y,mo,d] = date.split("-");
    store.set(`qa/${station}/${y}/${mo}/${d}/${f}`,
      { size, uploaded: new Date("2026-09-30T12:00:00Z"), body: Buffer.alloc(Math.min(size, 64)) });
  }
}
seed("funasia", "2026-09-30", [...Array(18)].map((_,i)=>i+6));
seed("sangam",  "2026-09-30", [...Array(16)].map((_,i)=>i+6));   // 2 hours missing

const ARCHIVE = {
  async list({ prefix, limit = 1000 }) {
    const objects = [...store.entries()].filter(([k]) => k.startsWith(prefix))
      .slice(0, limit).map(([key, v]) => ({ key, size: v.size, uploaded: v.uploaded }));
    return { objects, truncated: false };
  },
  async head(key) { const v = store.get(key); return v ? { size: v.size } : null; },
  async get(key, opts) {
    const v = store.get(key); if (!v) return null;
    if (opts?.range) return { body: v.body, size: opts.range.length };
    return { body: v.body, size: v.size };
  },
};
const env = { ARCHIVE, STATIONS: "sangam,funasia,vanakkam,apnapunjab", API_TOKEN: "s3cret" };
const BASE = "https://api.test";
const call = (p, h = {}) => worker.fetch(new Request(BASE + p, { headers: h }), env);
const AUTH = { Authorization: "Bearer s3cret" };

let fails = 0;
async function t(name, fn) {
  try { await fn(); console.log(`  PASS  ${name}`); }
  catch (e) { fails++; console.log(`  FAIL  ${name}\n          ${e.message}`); }
}
const eq = (a, b, m) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${m||""} got ${JSON.stringify(a)} want ${JSON.stringify(b)}`); };
const ok = (c, m) => { if (!c) throw new Error(m); };

await t("/health needs no auth", async () => eq((await call("/health")).status, 200));
await t("auth required elsewhere", async () => eq((await call("/recordings?date=2026-09-30")).status, 401));
await t("bad token rejected", async () => eq((await call("/stations", {Authorization:"Bearer nope"})).status, 401));
await t("token via ?token= works", async () => eq((await call("/stations?token=s3cret")).status, 200));
await t("CORS preflight", async () => {
  const r = await worker.fetch(new Request(BASE+"/recordings",{method:"OPTIONS"}), env);
  eq(r.status, 204); ok(r.headers.get("Access-Control-Allow-Origin")==="*", "no CORS header");
});
await t("POST rejected", async () => {
  eq((await worker.fetch(new Request(BASE+"/stations",{method:"POST",headers:AUTH}), env)).status, 405);
});
await t("/stations lists 4", async () => {
  const b = await (await call("/stations", AUTH)).json();
  eq(b.stations.length, 4); eq(b.qa_profile.bitrate_kbps, 16);
});
await t("/recordings one station/day", async () => {
  const b = await (await call("/recordings?station=funasia&date=2026-09-30", AUTH)).json();
  eq(b.count, 18);
  const r = b.recordings[0];
  eq(r.station, "funasia"); eq(r.start_local, "06:00:00");
  eq(r.duration_seconds, 3600, "duration from size");
  ok(r.start_iso.endsWith("-05:00"), `CDT offset, got ${r.start_iso}`);
  ok(r.audio_url.startsWith("https://api.test/audio/qa/"), "audio_url");
});
await t("/recordings all stations sorted", async () => {
  const b = await (await call("/recordings?date=2026-09-30", AUTH)).json();
  eq(b.count, 34);
  const iso = b.recordings.map(r=>r.start_iso);
  eq(iso, [...iso].sort(), "not sorted");
});
await t("/recordings rejects bad date", async () => eq((await call("/recordings?date=30-09-2026", AUTH)).status, 400));
await t("/recordings needs a range", async () => eq((await call("/recordings", AUTH)).status, 400));
await t("/recordings from/to range", async () => {
  const b = await (await call("/recordings?station=funasia&from=2026-09-29&to=2026-09-30", AUTH)).json();
  eq(b.count, 18);
});
await t("/recordings limit + truncated flag", async () => {
  const b = await (await call("/recordings?date=2026-09-30&limit=5", AUTH)).json();
  eq(b.count, 5); eq(b.truncated, true);
});
await t("/coverage flags the incomplete station", async () => {
  const b = await (await call("/coverage?date=2026-09-30", AUTH)).json();
  eq(b.complete, false);
  const f = b.stations.find(s=>s.station==="funasia"), s = b.stations.find(s=>s.station==="sangam");
  eq(f.complete, true); eq(f.hours_ok, 18);
  eq(s.complete, false); eq(s.hours_ok, 16); eq(s.gaps.map(g=>g.hour), [22,23]);
  const v = b.stations.find(s=>s.station==="vanakkam");
  eq(v.hours_ok, 0, "station with no data");
});
await t("/audio full object", async () => {
  const r = await call("/audio/qa/funasia/2026/09/30/funasia_2026-09-30_060000_CT.mp3", AUTH);
  eq(r.status, 200); eq(r.headers.get("Content-Type"), "audio/mpeg");
  eq(r.headers.get("Accept-Ranges"), "bytes");
});
await t("/audio Range -> 206", async () => {
  const r = await call("/audio/qa/funasia/2026/09/30/funasia_2026-09-30_060000_CT.mp3",
                       {...AUTH, Range: "bytes=0-99"});
  eq(r.status, 206);
  eq(r.headers.get("Content-Range"), `bytes 0-99/${FULL}`);
  eq(r.headers.get("Content-Length"), "100");
});
await t("/audio suffix Range", async () => {
  const r = await call("/audio/qa/funasia/2026/09/30/funasia_2026-09-30_060000_CT.mp3",
                       {...AUTH, Range: "bytes=-500"});
  eq(r.status, 206); eq(r.headers.get("Content-Range"), `bytes ${FULL-500}-${FULL-1}/${FULL}`);
});
await t("/audio unsatisfiable Range -> 416", async () => {
  const r = await call("/audio/qa/funasia/2026/09/30/funasia_2026-09-30_060000_CT.mp3",
                       {...AUTH, Range: `bytes=${FULL+10}-${FULL+20}`});
  eq(r.status, 416);
});
await t("/audio 404 for missing", async () => eq((await call("/audio/qa/funasia/2026/09/30/nope.mp3", AUTH)).status, 404));
await t("/audio rejects key outside qa|raw", async () => eq((await call("/audio/secret", AUTH)).status, 400));
await t("/audio rejects ENCODED traversal", async () =>
  eq((await call("/audio/qa%2F..%2F..%2Fsecret", AUTH)).status, 400));
await t("/audio unencoded ../ is normalised away by URL", async () =>
  eq((await call("/audio/../../secret", AUTH)).status, 404));
await t("unknown endpoint 404", async () => eq((await call("/nope", AUTH)).status, 404));



// ---- /stats ----
await t("/stats returns per-day history", async () => {
  const b = await (await call("/stats?days=3&to=2026-09-30&station=funasia", AUTH)).json();
  eq(b.to, "2026-09-30");
  eq(b.stations.length, 1);
  const s = b.stations[0];
  eq(s.days.length, 3, "one entry per day");
  eq(s.days[2].date, "2026-09-30");
  eq(s.days[2].hours_ok, 18, "seeded day is complete");
  eq(s.days[0].files, 0, "unseeded day empty");
  ok(s.summary.reliability > 0 && s.summary.reliability <= 1, `reliability ${s.summary.reliability}`);
});
await t("/stats counts all stations by default", async () => {
  const b = await (await call("/stats?days=1&to=2026-09-30", AUTH)).json();
  eq(b.stations.length, 4);
  const sangam = b.stations.find(s => s.station === "sangam");
  eq(sangam.days[0].hours_ok, 16, "sangam is missing 2 hours");
  eq(sangam.days[0].gaps, [22, 23]);
});
await t("/stats caps the window", async () => {
  const b = await (await call("/stats?days=999&to=2026-09-30&station=funasia", AUTH)).json();
  ok(b.days <= 92, `days capped, got ${b.days}`);
});
await t("/stats requires auth", async () => eq((await call("/stats?days=1")).status, 401));
await t("/stats rejects a bad date", async () =>
  eq((await call("/stats?to=nonsense", AUTH)).status, 400));

await t("/me reports token access when no Access JWT", async () => {
  const b = await (await call("/me", AUTH)).json();
  eq(b.signed_in, true);
  eq(b.kind, "token");
});
await t("/me requires credentials", async () => eq((await call("/me")).status, 401));
await t("401 message mentions signing in", async () => {
  const b = await (await call("/stations")).json();
  ok(/funasia\.net/.test(b.detail), `got: ${b.detail}`);
});

console.log(`\n${fails ? fails + " FAILED" : "all passed"}`);
process.exit(fails ? 1 : 0);
