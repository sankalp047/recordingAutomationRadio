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

function bearerOK(request, env) {
  if (!env.API_TOKEN) return false;
  const h = request.headers.get("Authorization") || "";
  const token = h.startsWith("Bearer ") ? h.slice(7)
    : new URL(request.url).searchParams.get("token");
  return token === env.API_TOKEN;
}


// ---------------------------------------------------------------- identity

const TEAM_DOMAIN = "funasia.cloudflareaccess.com";
const ALLOWED_EMAIL_DOMAIN = "@funasia.net";

let certCache = { keys: null, at: 0 };

async function accessKeys() {
  // certs rotate; an hour is well inside that and avoids a fetch per request
  if (certCache.keys && Date.now() - certCache.at < 3600_000) return certCache.keys;
  const r = await fetch(`https://${TEAM_DOMAIN}/cdn-cgi/access/certs`);
  if (!r.ok) return certCache.keys || [];
  const { keys } = await r.json();
  certCache = { keys, at: Date.now() };
  return keys;
}

const b64urlToBytes = (s) => {
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(s.length / 4) * 4, "="));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
};

/**
 * Verify the JWT Cloudflare Access attaches to every request it lets through.
 *
 * Access already refuses anyone outside the policy before the Worker runs, so
 * this is defence in depth: it means the Worker is still safe if it is ever
 * reachable by a route that does not pass through Access. It also tells us who
 * is calling, which the app shows and which makes the logs meaningful.
 */
async function verifyAccess(request) {
  const token = request.headers.get("Cf-Access-Jwt-Assertion");
  if (!token) return null;
  const parts = token.split(".");
  if (parts.length !== 3) return null;

  let header, payload;
  try {
    header = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[0])));
    payload = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[1])));
  } catch { return null; }

  if (payload.iss !== `https://${TEAM_DOMAIN}`) return null;
  const now = Math.floor(Date.now() / 1000);
  if (payload.exp && payload.exp < now) return null;
  if (payload.nbf && payload.nbf > now) return null;

  const jwk = (await accessKeys()).find((k) => k.kid === header.kid);
  if (!jwk) return null;

  let ok = false;
  try {
    const key = await crypto.subtle.importKey(
      "jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
    ok = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5", key, b64urlToBytes(parts[2]),
      new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  } catch { return null; }
  if (!ok) return null;

  // A service token has no email; it is machine access, allowed by its own policy.
  const email = payload.email || null;
  if (email && !email.toLowerCase().endsWith(ALLOWED_EMAIL_DOMAIN)) return null;

  return {
    email,
    kind: email ? "user" : "service",
    name: payload.common_name || null,
    expires: payload.exp || null,
  };
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
    // People reach this through Cloudflare Access and need no key of their own.
    // The shared key stays only so scripts can call the Worker directly.
    const identity = await verifyAccess(request);
    if (!identity && !bearerOK(request, env)) {
      return err(401, "unauthorized",
        "Sign in with a funasia.net account, or send a valid API token.");
    }

    if (path === "/me") {
      return json(identity
        ? { signed_in: true, ...identity }
        : { signed_in: true, kind: "token", email: null, name: "API token" });
    }

    if (path === "/" ) {
      return json({
        service: "show-archive-api",
        endpoints: {
          "/health": "liveness",
          "/me": "who you are signed in as",
          "/stations": "configured stations",
          "/recordings": "?station=&date=|from=&to=&limit= - recording metadata",
          "/coverage": "?date=&station= - per-hour completeness for QA",
          "/stats": "?days=&to=&station= - per-day history, reliability and restarts",
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


    if (path === "/stats") {
      const to = url.searchParams.get("to") || new Intl.DateTimeFormat("en-CA", { timeZone: TZ }).format(new Date());
      const days = Math.min(parseInt(url.searchParams.get("days") || "14", 10), 92);
      if (!isDate(to)) return err(400, "bad to", "expected YYYY-MM-DD");
      const from = new Date(`${to}T00:00:00Z`);
      from.setUTCDate(from.getUTCDate() - (days - 1));
      const fromStr = from.toISOString().slice(0, 10);
      const stations = url.searchParams.get("station")
        ? [url.searchParams.get("station")] : stationList(env);

      const out = [];
      for (const st of stations) {
        // one listing covers the whole range; bucket in memory by day
        const objs = await listRange(env.ARCHIVE, st, fromStr, to);
        const byDay = new Map();
        for (const o of objs) {
          const m = NAME_RE.exec(o.key.split("/").pop());
          if (!m) continue;
          if (!byDay.has(m[2])) byDay.set(m[2], []);
          byDay.get(m[2]).push(o);
        }
        const daily = [];
        for (const d of daysBetween(fromStr, to)) {
          const dayObjs = byDay.get(d) || [];
          const c = coverage(dayObjs, st, d);
          const secs = dayObjs.reduce((a, o) => a + o.size / QA_BYTES_PER_SEC, 0);
          daily.push({
            date: d,
            complete: c.complete,
            hours_ok: c.hours_ok,
            hours_total: c.hours_total,
            files: c.files,
            // more files than hours means the recorder restarted mid-hour
            restarts: Math.max(0, c.files - (c.hours_total - c.gaps.length)),
            recorded_seconds: Math.round(secs),
            bytes: dayObjs.reduce((a, o) => a + o.size, 0),
            gaps: c.gaps.map((g) => g.hour),
          });
        }
        const withData = daily.filter((d) => d.files > 0);
        out.push({
          station: st,
          days: daily,
          summary: {
            days_counted: withData.length,
            days_complete: daily.filter((d) => d.complete).length,
            total_hours_ok: daily.reduce((a, d) => a + d.hours_ok, 0),
            total_hours_expected: daily.reduce((a, d) => a + d.hours_total, 0),
            total_files: daily.reduce((a, d) => a + d.files, 0),
            total_restarts: daily.reduce((a, d) => a + d.restarts, 0),
            total_bytes: daily.reduce((a, d) => a + d.bytes, 0),
            reliability: (() => {
              const exp = daily.reduce((a, d) => a + d.hours_total, 0);
              return exp ? Math.round((daily.reduce((a, d) => a + d.hours_ok, 0) / exp) * 1000) / 1000 : 0;
            })(),
          },
        });
      }
      return json({ from: fromStr, to, days, timezone: TZ, stations: out });
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
