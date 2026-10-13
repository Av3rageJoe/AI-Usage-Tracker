#!/usr/bin/env python3
"""Proof that cache_store() keeps "write one slot, preserving the other" under concurrency.

statusline.py promises it. That is a read-modify-write: unlocked, two writers each read
the file, each preserves the OTHER slot as it was AT READ TIME, and the second write discards
the first's fresh slot. The temp file was also one shared path, so os.replace could publish
another process's half-written file. The widget, the CLI and status lines run concurrently.

DESIGN NOTE — the first version of this test was worthless: it had each worker write its slot
40 times, so the last write of each kind always won and it passed against the PRE-FIX code.
A race test must give each writer exactly ONE chance to be clobbered. Each trial starts two
single-write processes together and asks whether both slots survived; the race shows up as a
lost slot across many trials.

Usage: statusline_cache_test.py [path-to-statusline.py]   (default: scripts/statusline.py)

It was validated against the pre-fix build (which lost a slot in most trials). A test that
passes against both builds proves nothing. Re-validate after any change.
"""
import contextlib, importlib.util, io, json, os, subprocess, sys, tempfile

SL = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "statusline.py")
TRIALS = 60

home = tempfile.mkdtemp(prefix="slcache-")
os.environ["AI_USAGE_TRACKER_HOME"] = os.path.join(home, "app-home")  # never the real one
worker = os.path.join(home, "w.py")
open(worker, "w").write(
    "import importlib.util,sys,time\n"
    "spec=importlib.util.spec_from_file_location('sl', %r)\n" % SL +
    "m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
    "m.cache_store(sys.argv[1], [{'slot': sys.argv[1]}], time.time())\n")

cache_path = subprocess.run(
    [sys.executable, "-c",
     "import importlib.util;spec=importlib.util.spec_from_file_location('sl', %r);"
     "m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);print(m.CACHE_PATH)" % SL],
    env={**os.environ, "HOME": home}, capture_output=True, text=True, timeout=60).stdout.strip()
assert cache_path, "could not resolve CACHE_PATH"

lost = corrupt = 0
for _ in range(TRIALS):
    try:
        os.unlink(cache_path)
    except OSError:
        pass
    env = {**os.environ, "HOME": home}
    ps = [subprocess.Popen([sys.executable, worker, k], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
          for k in ("live", "scrape")]
    for p in ps: p.wait(timeout=60)
    try:
        data = json.load(open(cache_path))
    except Exception:
        corrupt += 1
        continue
    if not (isinstance(data.get("live"), dict) and isinstance(data.get("scrape"), dict)):
        lost += 1

strays = [f for f in os.listdir(os.path.dirname(cache_path)) if ".tmp" in f and not f.endswith(".lock")]
ok, fail = [], []
def check(name, cond, d=""):
    (ok if cond else fail).append(name)
    print(("  \033[32m✓\033[0m " if cond else "  \033[31m✗\033[0m ") + name + (("  " + d) if d else ""))

print("=== %d trials, 2 concurrent single-write processes each — %s ===" % (TRIALS, SL))
check("no trial lost a slot", lost == 0, "lost in %d/%d trials" % (lost, TRIALS))
check("no trial corrupted the cache", corrupt == 0, "corrupt in %d/%d" % (corrupt, TRIALS))
check("no stray temp files left behind", not strays, ",".join(strays[:3]))

spec = importlib.util.spec_from_file_location("statusline_under_test", SL)
sl = importlib.util.module_from_spec(spec); spec.loader.exec_module(sl)
sl.NO_COLOR = True
sl.cache_store = lambda *args: None
sl.read_codex_accounts = lambda live=True: [
    {"label": "A", "home": os.path.join(home, ".codex"), "source": "live",
     "stale": False, "slots": {"7d": {"pct": 16.0}, "5h": {"pct": 100.0}}},
    {"label": "B", "home": os.path.join(home, ".codex-alt"), "source": "live",
     "stale": False, "slots": {"7d": {"pct": 90.0}, "5h": {"pct": 20.0}}},
]
captured = io.StringIO()
with contextlib.redirect_stdout(captured): sl.report()
dispatch = next((line for line in captured.getvalue().splitlines()
                 if "Dispatch with CODEX_HOME" in line), "")
check("C22 dispatch rejects an account spent on 5h", "account B" in dispatch, dispatch)
print("\n%d passed, %d failed" % (len(ok), len(fail)))
sys.exit(1 if fail else 0)
