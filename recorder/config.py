"""Configuration, from environment variables with sane defaults.

On Render everything is set in the dashboard; stations can come either from
config/stations.conf (version controlled, not secret) or the STATIONS env var.
"""
import os, pathlib, re

ROOT = pathlib.Path(__file__).resolve().parent.parent

def _env(k, d=None):
    v = os.environ.get(k)
    return v if v not in (None, "") else d

TZ_NAME   = _env("TZ_NAME", "America/Chicago")
REC_START = _env("REC_START", "06:00")
REC_END   = _env("REC_END", "00:00")

QA_BITRATE    = _env("QA_BITRATE", "16k")
QA_SAMPLERATE = int(_env("QA_SAMPLERATE", "16000"))
QA_EXT        = "mp3"
# 16 kbps CBR -> 2000 bytes/sec. Duration is derived from size everywhere,
# so this constant has to match QA_BITRATE or coverage reporting goes wrong.
QA_BYTES_PER_SEC  = int(re.sub(r"\D", "", QA_BITRATE)) * 1000 // 8
QA_BYTES_PER_HOUR = QA_BYTES_PER_SEC * 3600

SPOOL_DIR = pathlib.Path(_env("SPOOL_DIR", "/tmp/spool"))
WORK_DIR  = pathlib.Path(_env("WORK_DIR", "/tmp/work"))

R2_ACCOUNT_ID        = _env("R2_ACCOUNT_ID")
R2_ACCESS_KEY_ID     = _env("R2_ACCESS_KEY_ID")
R2_SECRET_ACCESS_KEY = _env("R2_SECRET_ACCESS_KEY")
R2_BUCKET            = _env("R2_BUCKET", "show-archive")

SEGMENT_SECONDS = int(_env("SEGMENT_SECONDS", "3600"))
UPLOAD_INTERVAL = int(_env("UPLOAD_INTERVAL", "300"))
KEEP_RAW        = _env("KEEP_RAW", "1") not in ("0", "false", "no")
ALERT_WEBHOOK   = _env("ALERT_WEBHOOK")

def stations():
    """[(id, url)] from $STATIONS ('id=url,id=url') or config/stations.conf."""
    raw = _env("STATIONS")
    if raw:
        out = []
        for part in raw.split(","):
            if "=" in part:
                i, u = part.split("=", 1)
                out.append((i.strip(), u.strip()))
        return out
    out = []
    conf = ROOT / "config" / "stations.conf"
    if conf.exists():
        for line in conf.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            f = line.split()
            if len(f) >= 2:
                out.append((f[0], f[1]))
    return out

def window_hours():
    sh = int(REC_START.split(":")[0])
    eh = 24 if REC_END == "00:00" else int(REC_END.split(":")[0])
    return sh, eh
