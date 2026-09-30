#!/usr/bin/env python3
"""Unit tests for the gap-detection coverage maths."""
import json, subprocess, sys, pathlib
COV = str(pathlib.Path(__file__).resolve().parent.parent / "recorder" / "coverage.py")
BPS, FULL = 2000, 7200000          # 16 kbps CBR -> 2000 B/s; a full hour in bytes

def run(objs, sh=6, eh=24):
    p = subprocess.run([sys.executable, COV, "--station", "kzmp", "--day", "2026-09-30",
                        "--start-hour", str(sh), "--end-hour", str(eh),
                        "--bytes-per-sec", str(BPS)],
                       input=json.dumps(objs), capture_output=True, text=True)
    return p.stdout.strip(), p.returncode

def o(h, m=0, s=0, size=FULL):
    return {"Name": f"kzmp_2026-09-30_{h:02d}{m:02d}{s:02d}_CT.mp3", "Size": size}

CASES = []
def case(name, objs, want_rc, want_in=None):
    CASES.append((name, objs, want_rc, want_in))

case("perfect 18-hour day",            [o(h) for h in range(6, 24)], 0)
case("total failure / empty bucket",   [], 1, "0/18")
case("recorder died at 15:00",         [o(h) for h in range(6, 15)], 1, "9/18")
case("one genuinely short hour",       [o(h) for h in range(6,24) if h!=9] + [o(9,0,0,int(FULL*0.33))], 1, "09:00=33%")
case("mid-hour restart, two partials", [o(h) for h in range(6,24) if h!=14] +
                                       [o(14,0,0,int(FULL*0.4)), o(14,24,0,int(FULL*0.6))], 0)
# the case the old filename-bucketing version got wrong:
case("UNALIGNED segments spanning hours",
     [o(6,0,0,int(FULL*1.5)), o(7,30,0,int(FULL*1.5)), o(9,0,0,int(FULL*1.5)),
      o(10,30,0,int(FULL*1.5))] + [o(h) for h in range(12,24)], 0)
case("segment straddling midnight is clamped",
     [o(h) for h in range(6,23)] + [o(23,0,0,int(FULL*2))], 0)
case("overlapping duplicates not double-counted",
     [o(h) for h in range(6,24)] + [o(8,0,0,FULL)], 0)
case("other station's files ignored",
     [o(h) for h in range(6,24)] + [{"Name":"other_2026-09-30_060000_CT.mp3","Size":FULL}], 0)
case("other day's files ignored",
     [o(h) for h in range(6,24)] + [{"Name":"kzmp_2026-09-29_060000_CT.mp3","Size":FULL}], 0)
case("malformed names ignored",
     [o(h) for h in range(6,24)] + [{"Name":"garbage.mp3","Size":FULL}], 0)

fails = 0
for name, objs, want_rc, want_in in CASES:
    out, rc = run(objs)
    ok = (rc == want_rc) and (want_in is None or want_in in out)
    if not ok:
        fails += 1
    print(f"  {'PASS' if ok else 'FAIL'}  {name:42s} rc={rc} | {out}")
print(f"\n{len(CASES)-fails}/{len(CASES)} passed")
sys.exit(1 if fails else 0)
