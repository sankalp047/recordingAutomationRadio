#!/usr/bin/env python3
"""Records N streams during the daily broadcast window and files them in R2.

Replaces the systemd/shell setup, which does not exist in a container. One
process owns everything:

  * one ffmpeg child per station, started at REC_START and stopped at REC_END
  * a background thread that transcodes closed segments and uploads them
  * a daily coverage check that alerts on any incomplete hour

Render sends SIGTERM on every deploy and restart, and the filesystem is
ephemeral, so shutdown matters: we stop ffmpeg (which closes the current
segment as a valid file), then drain the upload queue before exiting. A
redeploy therefore costs seconds, not the current hour.
"""
import os, re, signal, subprocess, sys, threading, time, urllib.request, json
import datetime as dt
import pathlib
from zoneinfo import ZoneInfo

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from recorder import config as C
from recorder import storage
from recorder.coverage import intervals, merge, coverage

TZ = ZoneInfo(C.TZ_NAME)
SEG_RE = re.compile(r"^(.+)_(\d{4}-\d{2}-\d{2})_(\d{6})_CT\.(mp3|aac)$")

_stop = threading.Event()

def log(*a):
    print(dt.datetime.now(TZ).strftime("%F %T %Z"), "|", *a, flush=True)

def alert(subject, body):
    log("ALERT:", subject, "-", body.replace("\n", " ")[:300])
    if not C.ALERT_WEBHOOK:
        return
    try:
        req = urllib.request.Request(
            C.ALERT_WEBHOOK,
            data=json.dumps({"text": f"*{subject}*\n{body}"}).encode(),
            headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=15).read()
    except Exception as e:
        log("webhook failed:", e)

# ---------------------------------------------------------------- window

def window_bounds(now=None):
    """(start, end) datetimes for the broadcast day `now` falls in."""
    now = now or dt.datetime.now(TZ)
    sh, sm = (int(x) for x in C.REC_START.split(":"))
    start = now.replace(hour=sh, minute=sm, second=0, microsecond=0)
    if C.REC_END == "00:00":
        end = start.replace(hour=0, minute=0) + dt.timedelta(days=1)
    else:
        eh, em = (int(x) for x in C.REC_END.split(":"))
        end = now.replace(hour=eh, minute=em, second=0, microsecond=0)
    return start, end

def in_window(now=None):
    now = now or dt.datetime.now(TZ)
    start, end = window_bounds(now)
    return start <= now < end

# ---------------------------------------------------------------- ffmpeg

def probe_codec(url):
    """Stream codec, or None if unreachable. Determines the container: copying
    AAC into an .mp3 container fails outright and records nothing."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-rw_timeout", "20000000",
             "-analyzeduration", "3000000", "-select_streams", "a:0",
             "-show_entries", "stream=codec_name", "-of", "csv=p=0", url],
            capture_output=True, text=True, timeout=60).stdout.strip().splitlines()
        return out[0].strip() if out else None
    except Exception:
        return None

def container_for(codec):
    return {"mp3": ("mp3", "mp3"), "aac": ("aac", "adts")}.get(codec)

_RECONNECT_CACHE = None
def reconnect_args():
    """Only the reconnect options this ffmpeg build knows. Passing an unknown
    one makes ffmpeg refuse to start, which would mean recording nothing."""
    global _RECONNECT_CACHE
    if _RECONNECT_CACHE is None:
        try:
            h = subprocess.run(["ffmpeg", "-hide_banner", "-h", "protocol=https"],
                               capture_output=True, text=True, timeout=30).stdout
        except Exception:
            h = ""
        a = ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "30"]
        if "reconnect_on_network_error" in h:
            a += ["-reconnect_on_network_error", "1"]
        if "reconnect_on_http_error" in h:
            a += ["-reconnect_on_http_error", "5xx"]
        _RECONNECT_CACHE = a
    return _RECONNECT_CACHE

class Recorder:
    """One station's ffmpeg child, restarted on failure while in-window."""
    def __init__(self, station, url):
        self.station, self.url = station, url
        self.proc = None
        self.codec = None
        self.fails = 0
        self.next_try = 0.0

    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def start(self):
        if time.time() < self.next_try:
            return
        if self.codec is None:
            self.codec = probe_codec(self.url)
            if self.codec is None:
                self.fails += 1
                self.next_try = time.time() + min(300, 15 * self.fails)
                log(f"{self.station}: probe failed (retry {int(self.next_try-time.time())}s)")
                return
        cont = container_for(self.codec)
        if cont is None:
            log(f"{self.station}: unsupported codec {self.codec!r} - not recording")
            self.next_try = time.time() + 3600
            return
        ext, segfmt = cont
        _, end = window_bounds()
        remaining = int((end - dt.datetime.now(TZ)).total_seconds())
        if remaining <= 30:
            return
        C.SPOOL_DIR.mkdir(parents=True, exist_ok=True)
        cmd = (["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "warning"]
               + reconnect_args()
               + ["-rw_timeout", "30000000", "-i", self.url,
                  "-t", str(remaining), "-c", "copy", "-vn",
                  "-f", "segment", "-segment_time", str(C.SEGMENT_SECONDS),
                  "-segment_atclocktime", "1", "-segment_format", segfmt,
                  "-strftime", "1", "-reset_timestamps", "1",
                  str(C.SPOOL_DIR / f"{self.station}_%Y-%m-%d_%H%M%S_CT.{ext}")])
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL)
        log(f"{self.station}: recording ({self.codec}/{segfmt}) for {remaining}s")

    def reap(self):
        """Note an exit and back off, so a dead stream doesn't spin."""
        if self.proc is None or self.proc.poll() is None:
            return
        rc = self.proc.returncode
        self.proc = None
        if in_window() and rc != 0:
            self.fails += 1
            self.next_try = time.time() + min(300, 15 * self.fails)
            log(f"{self.station}: ffmpeg exited rc={rc}, retry in "
                f"{int(self.next_try - time.time())}s")
        elif rc == 0:
            self.fails = 0

    def stop(self):
        if self.running():
            log(f"{self.station}: stopping")
            self.proc.terminate()
            try:
                self.proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None

# ---------------------------------------------------------------- uploads

def closed_segments(drain=False):
    """Segments ffmpeg has finished with.

    While recording, "finished" is inferred from age: segments are an hour
    long, so anything untouched for two minutes is certainly complete.

    On shutdown the recorders are already stopped, so every file in the spool
    is closed by definition and the age test must be skipped - otherwise the
    segment ffmpeg just flushed is judged too fresh, never uploaded, and lost
    with the container. Pass drain=True there.
    """
    if not C.SPOOL_DIR.exists():
        return []
    cutoff = float("inf") if drain else time.time() - 120
    return sorted(p for p in C.SPOOL_DIR.iterdir()
                  if p.is_file() and p.suffix in (".mp3", ".aac")
                  and p.stat().st_mtime < cutoff)

def transcode(src: pathlib.Path, dst: pathlib.Path):
    r = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
         "-i", str(src), "-c:a", "libmp3lame", "-b:a", C.QA_BITRATE,
         "-ac", "1", "-ar", str(C.QA_SAMPLERATE), str(dst)],
        capture_output=True, text=True)
    return r.returncode == 0, r.stderr.strip()

def process_once(drain=False):
    """Transcode + upload every closed segment. Anything that fails is left in
    the spool and retried on the next pass."""
    segs = closed_segments(drain)
    if not segs:
        return 0, 0
    C.WORK_DIR.joinpath("tmp").mkdir(parents=True, exist_ok=True)
    ok = fail = 0
    for f in segs:
        m = SEG_RE.match(f.name)
        if not m:
            log("skip unparseable:", f.name)
            continue
        station, day, hms, _ = m.groups()
        size = f.stat().st_size
        if size < 100_000 and not drain:       # a stub from a failed connect
            log(f"skip runt {f.name} ({size} B)")
            f.unlink(missing_ok=True)
            continue
        if size < 2000:                        # nothing decodable, even draining
            log(f"skip empty {f.name} ({size} B)")
            f.unlink(missing_ok=True)
            continue
        qa_name = f"{station}_{day}_{hms}_CT.{C.QA_EXT}"
        qa_tmp = C.WORK_DIR / "tmp" / qa_name
        good, err = transcode(f, qa_tmp)
        if not good:
            log(f"FAIL transcode {f.name}: {err[:200]}")
            qa_tmp.unlink(missing_ok=True)
            fail += 1
            continue
        try:
            storage.upload(qa_tmp, storage.key_for("qa", station, day, qa_name))
            if C.KEEP_RAW:
                ct = "audio/aac" if f.suffix == ".aac" else "audio/mpeg"
                storage.upload(f, storage.key_for("raw", station, day, f.name), ct)
        except Exception as e:
            log(f"FAIL upload {qa_name}: {e}")
            qa_tmp.unlink(missing_ok=True)
            fail += 1
            continue
        qa_size = qa_tmp.stat().st_size
        qa_tmp.unlink(missing_ok=True)
        f.unlink(missing_ok=True)
        ok += 1
        log(f"OK {qa_name} ({size//1024} KB -> {qa_size//1024} KB)")
    if fail:
        alert(f"Recorder: {fail} segment(s) failed",
              f"{fail} segment(s) could not be transcoded or uploaded. "
              f"They stay in the spool and will be retried.")
    return ok, fail

def upload_loop():
    while not _stop.is_set():
        try:
            process_once()
        except Exception as e:
            log("upload loop error:", e)
        _stop.wait(C.UPLOAD_INTERVAL)

# ---------------------------------------------------------------- gap check

def gap_check(day=None):
    day = day or (dt.datetime.now(TZ).date() - dt.timedelta(days=1)).isoformat()
    sh, eh = C.window_hours()
    problems = []
    for station, _ in C.stations():
        try:
            objs = storage.list_day("qa", station, day)
        except Exception as e:
            problems.append(f"{station}: listing failed ({e})")
            continue
        iv = intervals(objs, station, day, C.QA_BYTES_PER_SEC)
        rows = coverage(merge(iv), sh, eh)
        bad = [(h, c) for h, c in rows if c < 0.95]
        log(f"gapcheck {day} {station}: {len(rows)-len(bad)}/{len(rows)} hours OK "
            f"({len(iv)} files)")
        if bad:
            problems.append(f"{station}: " +
                            " ".join(f"{h:02d}:00={int(c*100)}%" for h, c in bad))
    if problems:
        alert(f"Recording gaps on {day}", "\n".join(problems))
    return problems

# ---------------------------------------------------------------- main

def main():
    log("supervisor starting")
    log(f"window {C.REC_START}-{C.REC_END} {C.TZ_NAME} | "
        f"segments {C.SEGMENT_SECONDS}s | QA {C.QA_BITRATE} mono {C.QA_SAMPLERATE} Hz")
    try:
        storage.healthcheck()
        log(f"R2 bucket {C.R2_BUCKET!r} reachable")
    except Exception as e:
        log("FATAL: R2 unreachable:", e)
        return 1

    recs = [Recorder(s, u) for s, u in C.stations()]
    if not recs:
        log("FATAL: no stations configured")
        return 1
    log("stations:", ", ".join(r.station for r in recs))

    def on_term(signum, _frame):
        log(f"signal {signum} - draining")
        _stop.set()
    try:
        signal.signal(signal.SIGTERM, on_term)
        signal.signal(signal.SIGINT, on_term)
    except ValueError:
        # only possible in the main thread; harmless when embedded in tests
        log("could not install signal handlers (not main thread)")

    t = threading.Thread(target=upload_loop, daemon=True)
    t.start()

    last_gap_day = None
    while not _stop.is_set():
        now = dt.datetime.now(TZ)
        active = in_window(now)
        for r in recs:
            r.reap()
            if active and not r.running():
                r.start()
            elif not active and r.running():
                r.stop()
        # daily coverage check, once, shortly after the window closes
        if not active and now.hour == 0 and now.minute >= 30:
            today = now.date().isoformat()
            if last_gap_day != today:
                last_gap_day = today
                try:
                    gap_check()
                except Exception as e:
                    log("gapcheck error:", e)
        _stop.wait(10)

    log("stopping recorders")
    for r in recs:
        r.stop()
    log("final upload pass (draining spool)")
    try:
        process_once(drain=True)
    except Exception as e:
        log("final upload failed:", e)
    log("bye")
    return 0

if __name__ == "__main__":
    sys.exit(main())
