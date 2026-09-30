#!/usr/bin/env python3
"""The shutdown drain must finish inside the platform's SIGTERM grace period.

This is a regression test for real data loss: on 2026-09-30 the recorder was
restarted mid-hour and 33 minutes of audio from two stations was lost, because
the drain stopped four ffmpeg children sequentially (up to 20s each) and then
transcoded and uploaded four ~32 MB segments in series - comfortably past the
~30s Render allows between SIGTERM and SIGKILL.

It runs the real process_once(drain=True) against segments the size of a full
open hour, with uploads thoughout at a realistic rate.
"""
import os, pathlib, shutil, subprocess, sys, tempfile, threading, time

GRACE = 30.0            # Render: SIGTERM -> SIGKILL
UPLOAD_BYTES_PER_SEC = 12e6
ROOT = pathlib.Path(__file__).resolve().parent.parent


def build_segments(spool, n_stations=4, minutes=60):
    """Segments the size of a full open hour at 128 kbps."""
    src = spool / "_src.mp3"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-f", "lavfi", "-i", "anoisesrc=d=10:c=pink",
                    "-c:a", "libmp3lame", "-b:a", "128k", str(src)],
                   check=True, capture_output=True)
    for st in ["sangam", "funasia", "vanakkam", "apnapunjab"][:n_stations]:
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                        "-stream_loop", "-1", "-i", str(src),
                        "-t", str(minutes * 60), "-c", "copy",
                        str(spool / f"{st}_2026-09-30_060000_CT.mp3")],
                       check=True, capture_output=True)
    src.unlink()


def main():
    tmp = pathlib.Path(tempfile.mkdtemp())
    spool, work, fake_r2 = tmp / "spool", tmp / "work", tmp / "r2"
    for d in (spool, work / "tmp", fake_r2):
        d.mkdir(parents=True, exist_ok=True)

    os.environ.update(SPOOL_DIR=str(spool), WORK_DIR=str(work),
                      R2_ACCOUNT_ID="x", R2_ACCESS_KEY_ID="x",
                      R2_SECRET_ACCESS_KEY="x")
    sys.path.insert(0, str(ROOT))
    from recorder import storage

    lock = threading.Lock()
    uploaded = []

    def fake_upload(local, key, content_type="audio/mpeg"):
        time.sleep(pathlib.Path(local).stat().st_size / UPLOAD_BYTES_PER_SEC)
        dst = fake_r2 / key
        dst.parent.mkdir(parents=True, exist_ok=True)
        with lock:
            shutil.copy(local, dst)
            uploaded.append(key)

    storage.upload = fake_upload
    import recorder.supervisor as S

    print("  building 4 x 60-minute segments...")
    build_segments(spool, minutes=60)
    total_mb = sum(f.stat().st_size for f in spool.iterdir()) / 1e6
    print(f"  spool holds {total_mb:.0f} MB across {len(list(spool.iterdir()))} segments")

    t0 = time.time()
    ok, fail = S.process_once(drain=True)
    elapsed = time.time() - t0

    qa = [k for k in uploaded if k.startswith("qa/")]
    raw = [k for k in uploaded if k.startswith("raw/")]
    drained = not any(spool.iterdir())

    print(f"\n  drain: {elapsed:.1f}s of a {GRACE:.0f}s grace period")
    print(f"  uploaded ok={ok} fail={fail} | qa={len(qa)} raw={len(raw)}")
    print(f"  spool drained: {drained}")

    problems = []
    if elapsed >= GRACE:
        problems.append(f"drain took {elapsed:.1f}s, over the {GRACE:.0f}s grace period")
    if len(qa) != 4:
        problems.append(f"expected 4 qa objects, got {len(qa)}")
    if raw:
        problems.append(f"drain uploaded {len(raw)} raw objects; it should skip them")
    if not drained:
        problems.append("spool not drained")

    shutil.rmtree(tmp, ignore_errors=True)
    if problems:
        for p in problems:
            print(f"  FAIL  {p}")
        return 1
    print(f"  PASS  all 4 hours saved with {GRACE - elapsed:.0f}s to spare")
    return 0


if __name__ == "__main__":
    sys.exit(main())
