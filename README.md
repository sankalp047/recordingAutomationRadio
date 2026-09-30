# ShowAutomation

Records 4 radio streams 6:00 AM – 12:00 AM America/Chicago, transcodes them to a
small QA profile, files them in Cloudflare R2 by date, and serves them back as
JSON through an API that any platform can consume.

Built for QA: *did the show air, at the right time?* — not for archival fidelity.

**Retention: 3 years.** Cost grows for 36 months as the archive fills, then
stays flat forever:

| | stored | R2 | + Render | **total/mo** |
|---|---|---|---|---|
| month 1 | 16 GB | $0.24 | $7 | **$7.24** |
| month 12 | 189 GB | $2.84 | $7 | **$9.84** |
| month 24 | 379 GB | $5.68 | $7 | **$12.68** |
| **month 36+** | **568 GB** | **$8.52** | $7 | **$15.52 (flat)** |

It adds ~16 GB every month — linear, not compounding. Three-year total ≈ $410,
of which Render is $252.

---

## Architecture

```
 Render Background Worker              Cloudflare
 ┌─────────────────────────┐          ┌──────────────────────┐
 │ supervisor.py           │  upload  │  R2: show-archive    │
 │  ├ 4x ffmpeg -c copy    │ ───────► │   qa/…   3 years     │
 │  ├ transcode → 16k mono │          │   raw/…  48 hours    │
 │  └ daily gap check      │          └──────────┬───────────┘
 └─────────────────────────┘                     │ native binding
                                                 ▼
                                      ┌──────────────────────┐
                                      │ Worker: JSON API     │
                                      │  /recordings         │
                                      │  /coverage           │
                                      │  /audio (Range)      │
                                      └──────────────────────┘
```

Two pieces, each where it belongs. The recorder holds long-lived connections, so
it's a **Render Background Worker**, not a Web Service. The API sits next to the
bucket as a **Cloudflare Worker** with a native R2 binding — no access keys in
flight, no egress charge, no cold start, free at this volume.

## Stations

| id | station | codec | rate | bitrate |
|---|---|---|---|---|
| `sangam` | Radio Sangam | MP3 | 44.1 kHz | 128k |
| `funasia` | FunAsia (KZMP-FM) | MP3 | 48 kHz | 128k |
| `vanakkam` | Vanakkam FM | **AAC-LC** | 48 kHz | 120k |
| `apnapunjab` | Apna Punjab | **AAC-LC** | 48 kHz | 121k |

**They are not all the same codec.** Copying an AAC stream into an `.mp3`
container fails outright (`Exactly one MP3 audio stream is required`) and records
nothing, so the supervisor probes each stream and picks the container to match.
Everything is normalised to one QA profile afterwards, so the API and the gap
check see a single format.

## Capture rules

Capture uses `-c copy` and **never re-encodes** — a codec or CPU problem must not
be able to cost a recording. Transcoding happens afterwards, from a file already
on disk, and failures are retried on the next pass.

Render's filesystem is ephemeral and every deploy sends SIGTERM, so shutdown
matters: the supervisor stops ffmpeg (which closes the current segment as a valid
file), then **drains the spool with the age check disabled** before exiting. A
redeploy costs seconds, not the current hour.

Still: deploy outside 06:00–24:00 CT when you can. `autoDeploy` is off in
`render.yaml` for that reason.

## Naming

```
qa/<station>/<YYYY>/<MM>/<DD>/<station>_<YYYY-MM-DD>_<HHMMSS>_CT.mp3
qa/funasia/2026/09/30/funasia_2026-09-30_060000_CT.mp3
```

Full `HHMMSS`, not `HHMM`: two segments starting in the same minute (a flapping
stream restarting) would otherwise overwrite each other in R2.

## Deploy

**1. Cloudflare R2** — create bucket `show-archive`, then an API token scoped to
it (Object Read & Write). Apply retention:

```bash
aws s3api put-bucket-lifecycle-configuration \
  --endpoint-url https://<ACCOUNT_ID>.r2.cloudflarestorage.com \
  --bucket show-archive --lifecycle-configuration file://r2/lifecycle.json
```

**2. Render** — new Blueprint from this repo (`render.yaml`), then set the three
secrets in the dashboard: `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`,
`R2_SECRET_ACCESS_KEY`. Optionally `ALERT_WEBHOOK` (Slack-compatible).

**3. API**

```bash
cd api
npm install
npx wrangler secret put API_TOKEN      # pick a long random string
npx wrangler deploy
```

If `API_TOKEN` is unset the API is open — fine for a smoke test, not for real use.

## API

All JSON, CORS enabled, `Authorization: Bearer <API_TOKEN>` (or `?token=`).

| endpoint | purpose |
|---|---|
| `GET /health` | liveness, no auth |
| `GET /stations` | configured stations + QA profile |
| `GET /recordings?station=&date=` | one station-day |
| `GET /recordings?date=` | all stations that day |
| `GET /recordings?from=&to=` | date range (max 366 days/request) |
| `GET /coverage?date=` | **per-hour completeness — the QA endpoint** |
| `GET /audio/<id>` | stream audio, supports `Range` for seeking |

```jsonc
// GET /recordings?station=funasia&date=2026-09-30
{
  "count": 18,
  "recordings": [{
    "id": "qa/funasia/2026/09/30/funasia_2026-09-30_060000_CT.mp3",
    "station": "funasia",
    "date": "2026-09-30",
    "start_local": "06:00:00",
    "start_iso": "2026-09-30T06:00:00-05:00",
    "duration_seconds": 3600,
    "size_bytes": 7200000,
    "audio_url": "https://…/audio/qa/funasia/2026/09/30/funasia_2026-09-30_060000_CT.mp3"
  }]
}

// GET /coverage?date=2026-09-30
{
  "date": "2026-09-30",
  "complete": false,
  "stations": [
    { "station": "funasia", "complete": true,  "hours_ok": 18, "hours_total": 18, "gaps": [] },
    { "station": "sangam",  "complete": false, "hours_ok": 16, "hours_total": 18,
      "gaps": [{ "hour": 22, "coverage": 0 }, { "hour": 23, "coverage": 0.41 }] }
  ]
}
```

`duration_seconds` is derived from object size — the QA profile is CBR at 2000
B/s, so size *is* duration. No metadata store needed.

## Querying a 3-year archive

Keys are date-partitioned, so the API picks the **coarsest R2 prefix that covers
the range** and filters the leftover days in memory — a whole month or a whole
year is one list call, not one per day. Listing per day instead would issue 1,460
R2 calls for a year, far past the Workers subrequest limit (50 free / 1000 paid).

A single request spans at most 366 days; split a full 3-year sweep by year. At
72 objects/day the archive reaches ~79,000 objects, which R2 handles fine — but
bulk exports should page by month rather than asking for everything at once.

## Coverage, and why it is not filename bucketing

Both the API and the recorder compute per-hour coverage from **real time
intervals**: start from the filename, duration from the size, merged and
intersected with each hour. This stays correct when segments are not hour-aligned
— which happens on a mid-hour restart, and on ffmpeg builds where
`-segment_atclocktime` aligns the first cut then drifts (verified: it does).

Don't "simplify" either implementation back to bucketing by the hour in the
filename. It silently reports false gaps and misses real ones.

The two implementations are held in agreement by running the **same fixtures**
in both languages.

## Tests

```bash
python3 tests/test_coverage.py     # 11 cases - recorder coverage maths
node api/test/coverage.test.js     # same 11 fixtures - Worker must agree
node api/test/api.test.js          # 23 cases - routing, auth, CORS, Range
node api/test/range.test.js        # 11 cases - multi-year ranges, prefix efficiency
```

## Configuration

Everything is environment variables (see `render.yaml`); `config/stations.conf`
holds the station list and is not secret. Key knobs:

| var | default | note |
|---|---|---|
| `REC_START` / `REC_END` | `06:00` / `00:00` | local to `TZ_NAME` |
| `TZ_NAME` | `America/Chicago` | never a fixed `CST` — this tracks DST |
| `QA_BITRATE` | `16k` | change and the API's `QA_BYTES_PER_SEC` must match |
| `SEGMENT_SECONDS` | `3600` | lower = less lost to an unclean crash, more objects |
| `KEEP_RAW` | `1` | 48 h untouched originals, ~$0.12/mo insurance |

Retention lives in `r2/lifecycle.json` (`qa/` = 1095 days), not in the app.
Lifecycle deletion is irreversible, so widen the window *before* you accumulate
history you want to keep.

The 6 AM–midnight window never crosses the 2 AM DST transition, so no broadcast
day gains or loses an hour. Verified across spring-forward and fall-back.
