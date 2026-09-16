#!/data/data/com.termux/files/usr/bin/bash
# report.sh — turn a finished (or running) soak into a verdict you can read in a minute.
#
# Answers ticket #2's exit criteria directly: did it survive, did memory creep,
# did anything have to be restarted, and did the corner-case probes keep passing.
set -u
LAB="${LAB:-$HOME/job-search-pipeline-data}"
CSV="$LAB/soak.csv"
EVT="$LAB/soak-events.jsonl"
PRB="$LAB/probes.jsonl"

[ -f "$CSV" ] || { echo "no soak data at $CSV"; exit 1; }

python - "$CSV" "$EVT" "$PRB" <<'PY'
import csv, json, sys, os
csv_path, evt_path, prb_path = sys.argv[1], sys.argv[2], sys.argv[3]

rows = []
with open(csv_path) as f:
    for r in csv.DictReader(f):
        rows.append(r)

def num(r, k):
    try: return float(r.get(k) or "")
    except ValueError: return None

print("=" * 66)
print("SOAK REPORT")
print("=" * 66)
if not rows:
    print("no cycles recorded"); raise SystemExit

ok = [r for r in rows if r.get("ok") == "1"]
bad = [r for r in rows if r.get("ok") != "1"]
print(f"cycles          : {len(rows)}   ok={len(ok)}   failed={len(bad)}")
print(f"window          : {rows[0]['ts']}  ->  {rows[-1]['ts']}")

# --- duration
try:
    from datetime import datetime
    t0 = datetime.strptime(rows[0]["ts"], "%Y-%m-%dT%H:%M:%S%z")
    t1 = datetime.strptime(rows[-1]["ts"], "%Y-%m-%dT%H:%M:%S%z")
    hrs = (t1 - t0).total_seconds() / 3600
    print(f"duration        : {hrs:.1f} h")
except Exception:
    hrs = None

# --- memory trend: the leak question
pss = [(i, num(r, "chrome_pss_kb")) for i, r in enumerate(rows)]
pss = [(i, v) for i, v in pss if v]
if len(pss) >= 2:
    first, last = pss[0][1], pss[-1][1]
    lo = min(v for _, v in pss); hi = max(v for _, v in pss)
    drift = last - first
    pct = (drift / first * 100) if first else 0
    print(f"chromium PSS    : first={first/1024:.0f}MB last={last/1024:.0f}MB "
          f"min={lo/1024:.0f}MB max={hi/1024:.0f}MB  drift={drift/1024:+.0f}MB ({pct:+.1f}%)")
    verdict = "STEADY" if abs(pct) < 25 else ("GROWING - possible leak" if pct > 0 else "shrinking")
    print(f"memory verdict  : {verdict}")

mem = [num(r, "mem_avail_kb") for r in rows]
mem = [m for m in mem if m]
if mem:
    print(f"MemAvailable    : min={min(mem)/1048576:.2f}GB max={max(mem)/1048576:.2f}GB last={mem[-1]/1048576:.2f}GB")

# --- timings
navs = [num(r, "nav_ms") for r in rows if num(r, "nav_ms")]
snaps = [num(r, "snapshot_ms") for r in rows if num(r, "snapshot_ms")]
def stat(name, xs):
    if not xs: return
    xs = sorted(xs)
    p50 = xs[len(xs)//2]; p95 = xs[int(len(xs)*0.95) - 1] if len(xs) > 1 else xs[0]
    print(f"{name:<16}: p50={p50:.0f}ms p95={p95:.0f}ms max={xs[-1]:.0f}ms n={len(xs)}")
stat("navigate", navs); stat("snapshot", snaps)

# --- did it creep slower over time? (staleness)
if len(navs) >= 6:
    h = len(navs)//2
    a = sum(navs[:h])/h; b = sum(navs[h:])/(len(navs)-h)
    print(f"nav drift       : first-half {a:.0f}ms -> second-half {b:.0f}ms ({(b-a)/a*100:+.0f}%)")

# --- battery
temps = [num(r, "batt_temp_c") for r in rows]; temps = [t for t in temps if t]
if temps:
    print(f"battery temp    : min={min(temps):.1f}C max={max(temps):.1f}C last={temps[-1]:.1f}C")

# --- restarts / gateway drift
restarts = sum(1 for r in rows if r.get("mcp_restarted") == "1")
print(f"stack restarts  : {restarts}")
for k, label in (("gw_upstreamrestarts", "upstream restarts"),
                 ("gw_reconciles", "lock reconciles"),
                 ("gw_timedout", "queue timeouts"),
                 ("gw_shed", "load shed"),
                 ("gw_idlereleases", "idle reclaims")):
    vals = [num(r, k) for r in rows]; vals = [v for v in vals if v is not None]
    if vals: print(f"{label:<16}: {vals[-1]:.0f} (cumulative)")

# --- neighbours
nb = set(r.get("neighbours", "") for r in rows) - {"ok", "", None}
print(f"neighbours      : {'ALL OK throughout' if not nb else 'DEGRADED: ' + ', '.join(sorted(nb))}")

# --- failures, named
if bad:
    print("\nfailed cycles:")
    for r in bad[:15]:
        print(f"  {r['ts']}  cycle {r['cycle']:>3}  {r.get('note') or 'unclassified'}  ({r.get('url','')[:44]})")

# --- abort?
aborted = None
if os.path.exists(evt_path):
    for line in open(evt_path):
        try: e = json.loads(line)
        except Exception: continue
        if e.get("evt") == "abort": aborted = e
if aborted:
    print(f"\n*** SOAK ABORTED: {aborted.get('reason')}  at {aborted.get('ts')}")

# --- probes
if os.path.exists(prb_path):
    probes = {}
    for line in open(prb_path):
        try: p = json.loads(line)
        except Exception: continue
        probes.setdefault(p["probe"], []).append(p)
    if probes:
        print("\ncorner-case probes:")
        for name, runs in sorted(probes.items()):
            passes = sum(1 for r in runs if r["verdict"] == "pass")
            fails = [r for r in runs if r["verdict"] == "fail"]
            infos = [r for r in runs if r["verdict"] == "info"]
            if infos and not fails and not passes:
                last = infos[-1]
                extra = " ".join(f"{k}={v}" for k, v in last.items()
                                 if k not in ("ts", "tag", "probe", "verdict"))
                print(f"  {name:<12} info  n={len(runs)}  {extra}")
            else:
                flag = "OK " if not fails else "FAIL"
                print(f"  {name:<12} {flag}  {passes}/{len(runs)} passed")
                for fr in fails[:3]:
                    extra = " ".join(f"{k}={v}" for k, v in fr.items()
                                     if k not in ("ts", "tag", "probe", "verdict"))
                    print(f"      failed {fr['ts']}: {extra}")

# --- the verdict ticket #2 actually asks for
print("\n" + "-" * 66)
survived = not aborted and len(bad) == 0
if hrs and hrs >= 6 and survived:
    print("VERDICT: survived the night with no failed cycles.")
elif hrs and hrs >= 6:
    print(f"VERDICT: ran {hrs:.1f}h but {len(bad)} cycle(s) failed - see above.")
elif aborted:
    print("VERDICT: aborted early by a guard rail - not a clean run.")
else:
    print(f"VERDICT: only {hrs:.1f}h so far - too short to call." if hrs else "VERDICT: insufficient data.")
print("-" * 66)
PY
