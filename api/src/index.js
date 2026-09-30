/**
 * Show archive API - JSON over the recordings in R2.
 *
 * Runs as a Cloudflare Worker with a native R2 binding, so it needs no
 * credentials and no egress budget: reads from R2 inside Cloudflare are free.
 *
 *   GET /health
 *   GET /stations
 *   GET /recordings?station=&date=&from=&to=&limit=
 *   GET /coverage?date=&station=
 *   GET /audio/<station>/<YYYY>/<MM>/<DD>/<file>    (Range-capable audio)
 *
 * Every response is JSON with CORS enabled, so the same endpoints serve a web
 * dashboard, a mobile app or a cron job without per-platform work.
 */

const QA_BYTES_PER_SEC = 2000;           // 16 kbps CBR -> duration from size
const FULL_HOUR = QA_BYTES_PER_SEC * 3600;
const WINDOW_START = 6;
const WINDOW_END = 24;
const TZ = "America/Chicago";
const MAX_DAYS = 366;   // one request; narrow further for a full 3-year sweep

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "Authorization, Content-Type",
  "Access-Control-Max-Age": "86400",
};

const json = (body, status = 200, extra = {}) =>
  new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...CORS, ...extra },
  });

const err = (status, message, detail) =>
  json({ error: message, ...(detail ? { detail } : {}) }, status);

/** Offset like "-05:00" for a date in TZ, so timestamps are DST-correct. */
function tzOffset(dateStr) {
  const d = new Date(`${dateStr}T12:00:00Z`);
  const s = new Intl.DateTimeFormat("en-US", {
    timeZone: TZ, timeZoneName: "longOffset",
  }).format(d);
  const m = s.match(/GMT([+-]\d{2}:\d{2})/);
  return m ? m[1] : "-06:00";
}

const NAME_RE = /^(.+)_(\d{4}-\d{2}-\d{2})_(\d{2})(\d{2})(\d{2})_CT\.mp3$/;

function describe(obj, origin) {
  const file = obj.key.split("/").pop();
  const m = NAME_RE.exec(file);
  if (!m) return null;
  const [, station, date, hh, mm, ss] = m;
  const duration = obj.size / QA_BYTES_PER_SEC;
  return {
    id: obj.key,
    station,
    date,
    start_local: `${hh}:${mm}:${ss}`,
    start_iso: `${date}T${hh}:${mm}:${ss}${tzOffset(date)}`,
    duration_seconds: Math.round(duration * 10) / 10,
    size_bytes: obj.size,
    uploaded: obj.uploaded ? new Date(obj.uploaded).toISOString() : null,
    audio_url: `${origin}/audio/${obj.key}`,
  };
}

async function listPrefix(bucket, prefix) {
  const out = [];
  let cursor;
  do {
    const r = await bucket.list({ prefix, cursor, limit: 1000 });
    out.push(...r.objects);
    cursor = r.truncated ? r.cursor : undefined;
  } while (cursor);
  return out;
}

const listDay = (bucket, station, date) =>
  listPrefix(bucket, `qa/${station}/${date.slice(0,4)}/${date.slice(5,7)}/${date.slice(8,10)}/`);

/**
 * Coarsest prefix that still covers [from, to].
 *
 * Keys are date-partitioned (qa/station/YYYY/MM/DD/), so a range inside one
 * month is one prefix, inside one year is one prefix, and so on. Listing a
 * prefix per DAY instead would issue 1,460 R2 calls for a year - far past the
 * Workers subrequest limit - so the range is narrowed by prefix and the
 * leftover days are filtered out in memory.
 */
function rangePrefix(station, from, to) {
  const base = `qa/${station}/`;
  if (from.slice(0, 10) === to.slice(0, 10)) return base + from.slice(0,4) + "/" + from.slice(5,7) + "/" + from.slice(8,10) + "/";
  if (from.slice(0, 7) === to.slice(0, 7)) return base + from.slice(0,4) + "/" + from.slice(5,7) + "/";
  if (from.slice(0, 4) === to.slice(0, 4)) return base + from.slice(0,4) + "/";
  return base;
}

/** Objects for a station between two dates inclusive, filtered to the range. */
async function listRange(bucket, station, from, to) {
  const objs = await listPrefix(bucket, rangePrefix(station, from, to));
  return objs.filter((o) => {
    const m = NAME_RE.exec(o.key.split("/").pop());
    return m && m[2] >= from && m[2] <= to;
  });
}

/** Per-hour coverage from real intervals, not filename buckets - correct even
 *  when segments are not hour-aligned (a mid-hour restart splits an hour). */
function coverage(objects, station, date) {
  const iv = [];
  for (const o of objects) {
    const m = NAME_RE.exec(o.key.split("/").pop());
    if (!m || m[1] !== station || m[2] !== date) continue;
    const start = +m[3] * 3600 + +m[4] * 60 + +m[5];
    iv.push([start, start + o.size / QA_BYTES_PER_SEC]);
  }
  iv.sort((a, b) => a[0] - b[0]);
  const merged = [];
  for (const [a, b] of iv) {
    const last = merged[merged.length - 1];
    if (last && a <= last[1]) last[1] = Math.max(last[1], b);
    else merged.push([a, b]);
  }
  const hours = [];
  for (let h = WINDOW_START; h < WINDOW_END; h++) {
    const lo = h * 3600, hi = (h + 1) * 3600;
    let cov = 0;
    for (const [a, b] of merged) cov += Math.max(0, Math.min(hi, b) - Math.max(lo, a));
    hours.push({ hour: h, coverage: Math.round((cov / 3600) * 1000) / 1000 });
  }
  const gaps = hours.filter((x) => x.coverage < 0.95);
  return {
    station,
    complete: gaps.length === 0,
    hours_ok: hours.length - gaps.length,
    hours_total: hours.length,
    files: iv.length,
    gaps,
  };
}

function stationList(env) {
  return (env.STATIONS || "sangam,funasia,vanakkam,apnapunjab")
    .split(",").map((s) => s.trim()).filter(Boolean);
}

function daysBetween(from, to) {
  const out = [];
  let d = new Date(`${from}T00:00:00Z`);
  const end = new Date(`${to}T00:00:00Z`);
  while (d <= end && out.length < MAX_DAYS) {
    out.push(d.toISOString().slice(0, 10));
    d = new Date(d.getTime() + 86400000);
  }
  return out;
}

const isDate = (s) => /^\d{4}-\d{2}-\d{2}$/.test(s);
const daysInclusive = (a, b) =>
  Math.round((new Date(`${b}T00:00:00Z`) - new Date(`${a}T00:00:00Z`)) / 86400000) + 1;

function authorized(request, env) {
  if (!env.API_TOKEN) return true;               // unset = open (dev only)
  const h = request.headers.get("Authorization") || "";
  const token = h.startsWith("Bearer ") ? h.slice(7) : new URL(request.url).searchParams.get("token");
  return token === env.API_TOKEN;
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    if (request.method !== "GET") return err(405, "method not allowed");

    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    const origin = url.origin;

    if (path === "/health") {
      return json({ ok: true, service: "show-archive-api", time: new Date().toISOString() });
    }
    if (!authorized(request, env)) return err(401, "unauthorized", "send Authorization: Bearer <token>");

    if (path === "/" ) {
      return json({
        service: "show-archive-api",
        endpoints: {
          "/health": "liveness",
          "/stations": "configured stations",
          "/recordings": "?station=&date=|from=&to=&limit= - recording metadata",
          "/coverage": "?date=&station= - per-hour completeness for QA",
          "/audio/<id>": "stream one recording (supports Range)",
        },
      });
    }

    if (path === "/stations") {
      return json({
        timezone: TZ,
        window: { start_hour: WINDOW_START, end_hour: WINDOW_END },
        qa_profile: { codec: "mp3", bitrate_kbps: 16, channels: 1, sample_rate: 16000 },
        stations: stationList(env),
      });
    }

    if (path === "/recordings") {
      const station = url.searchParams.get("station");
      const date = url.searchParams.get("date");
      const from = url.searchParams.get("from");
      const to = url.searchParams.get("to");
      const limit = Math.min(parseInt(url.searchParams.get("limit") || "1000", 10), 5000);

      let dates;
      if (date) {
        if (!isDate(date)) return err(400, "bad date", "expected YYYY-MM-DD");
        dates = [date];
      } else if (from && to) {
        if (!isDate(from) || !isDate(to)) return err(400, "bad from/to", "expected YYYY-MM-DD");
        dates = daysBetween(from, to);
        if (!dates.length) return err(400, "empty range", "from must be <= to");
        if (from > to) return err(400, "empty range", "from must be <= to");
        if (daysInclusive(from, to) > MAX_DAYS) {
          return err(400, "range too large",
            `${daysInclusive(from, to)} days requested, max ${MAX_DAYS}; split the query`);
        }
      } else {
        return err(400, "missing range", "pass date=YYYY-MM-DD or from=&to=");
      }

      const stations = station ? [station] : stationList(env);
      const lo = dates[0], hi = dates[dates.length - 1];
      const items = [];
      for (const st of stations) {
        for (const o of await listRange(env.ARCHIVE, st, lo, hi)) {
          const rec = describe(o, origin);
          if (rec) items.push(rec);
        }
      }
      items.sort((a, b) => (a.start_iso < b.start_iso ? -1 : a.start_iso > b.start_iso ? 1 : 0));
      const truncated = items.length > limit;
      return json({
        query: { stations, dates: dates.length === 1 ? dates[0] : { from: dates[0], to: dates[dates.length - 1] } },
        count: Math.min(items.length, limit),
        truncated,
        recordings: items.slice(0, limit),
      });
    }

    if (path === "/coverage") {
      const date = url.searchParams.get("date");
      if (!date || !isDate(date)) return err(400, "bad date", "expected ?date=YYYY-MM-DD");
      const station = url.searchParams.get("station");
      const stations = station ? [station] : stationList(env);
      const results = [];
      for (const st of stations) {
        results.push(coverage(await listDay(env.ARCHIVE, st, date), st, date));
      }
      return json({
        date,
        window: { start_hour: WINDOW_START, end_hour: WINDOW_END, timezone: TZ },
        complete: results.every((r) => r.complete),
        stations: results,
      });
    }

    if (path.startsWith("/audio/")) {
      const key = decodeURIComponent(path.slice("/audio/".length));
      // R2 keys are flat, so ".." is not traversal - but reject it anyway so
      // there is nothing to reason about, encoded or not.
      if (!/^(qa|raw)\//.test(key) || key.split("/").includes("..")) {
        return err(400, "bad key", "expected qa/... or raw/...");
      }
      const range = request.headers.get("Range");
      // Range support is what lets an audio player seek instead of
      // downloading the whole hour first.
      let opts = {};
      let m;
      if (range && (m = /^bytes=(\d*)-(\d*)$/.exec(range))) {
        const head = await env.ARCHIVE.head(key);
        if (!head) return err(404, "not found", key);
        const size = head.size;
        let start = m[1] === "" ? size - parseInt(m[2], 10) : parseInt(m[1], 10);
        let end = m[1] === "" ? size - 1 : (m[2] === "" ? size - 1 : parseInt(m[2], 10));
        start = Math.max(0, start); end = Math.min(size - 1, end);
        if (start > end) return new Response(null, { status: 416, headers: { ...CORS, "Content-Range": `bytes */${size}` } });
        opts = { range: { offset: start, length: end - start + 1 } };
        const obj = await env.ARCHIVE.get(key, opts);
        if (!obj) return err(404, "not found", key);
        return new Response(obj.body, {
          status: 206,
          headers: {
            ...CORS,
            "Content-Type": key.endsWith(".aac") ? "audio/aac" : "audio/mpeg",
            "Content-Range": `bytes ${start}-${end}/${size}`,
            "Content-Length": String(end - start + 1),
            "Accept-Ranges": "bytes",
            "Cache-Control": "public, max-age=3600",
          },
        });
      }
      const obj = await env.ARCHIVE.get(key);
      if (!obj) return err(404, "not found", key);
      return new Response(obj.body, {
        headers: {
          ...CORS,
          "Content-Type": key.endsWith(".aac") ? "audio/aac" : "audio/mpeg",
          "Content-Length": String(obj.size),
          "Accept-Ranges": "bytes",
          "Cache-Control": "public, max-age=3600",
        },
      });
    }

    return err(404, "no such endpoint", path);
  },
};
