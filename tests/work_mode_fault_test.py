#!/usr/bin/env python3
"""Proof that a BROKEN budget check never looks like a healthy one.

"Unknown is not normal": a crashed check must be loud on every surface the widget and the
CLI read. The fault is injected into a COPY, so the real script is never touched. The
healthy runs use --simulate, so this test makes no network call and reads no Keychain.
"""
import importlib.util, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "scripts", "work-mode.py")
fails, passes = [], []


def check(name, cond, detail=""):
    (passes if cond else fails).append(name)
    print(("  \033[32m✓\033[0m " if cond else "  \033[31m✗\033[0m ") + name
          + (("  " + detail) if detail and not cond else ""))


tmp = tempfile.mkdtemp(prefix="wmfault-")
ENV = {**os.environ, "AI_USAGE_TRACKER_HOME": os.path.join(tmp, "app-home")}


def run(script, args):
    p = subprocess.run([sys.executable, script] + args, capture_output=True, text=True,
                       timeout=60, env=ENV)
    return p.returncode, p.stdout, p.stderr


# The copy sits beside a copy of statusline.py, exactly as the installer lays them out.
shutil.copy(os.path.join(HERE, "..", "scripts", "statusline.py"), tmp)
broken = os.path.join(tmp, "work-mode.py")
src = open(SRC).read()
assert "\ndef main():\n" in src
open(broken, "w").write(src.replace(
    "\ndef main():\n", "\ndef main():\n    raise RuntimeError('injected fault')\n", 1))

print("=== BROKEN check — every surface must say so ===")
rc, out, err = run(broken, ["--report"])
check("--report exits 3", rc == 3, "rc=%s" % rc)
check("--report is loud on stderr", "CHECK-BROKEN" in err)
rc, out, err = run(broken, ["--json"])
check("--json exits 3", rc == 3, "rc=%s" % rc)
try:
    check("--json emits machine-readable CHECK-BROKEN",
          json.loads(out.strip()).get("mode") == "CHECK-BROKEN")
except Exception as exc:
    check("--json emits machine-readable CHECK-BROKEN", False, str(exc))

print("=== CALLER MISUSE is its own class (exit 2), not a broken check ===")
rc, out, err = run(SRC, ["--simulate", "not-a-number", "--report"])
check("bad --simulate exits 2", rc == 2, "rc=%s" % rc)
check("bad --simulate explains usage", "simulate" in err.lower())

print("=== HEALTHY check still behaves (simulated, no network) ===")
rc, out, err = run(SRC, ["--simulate", "20", "--report"])
check("--report exits 0 when healthy", rc == 0, "rc=%s" % rc)
check("--report says nothing about CHECK-BROKEN", "CHECK-BROKEN" not in err + out)
rc, out, err = run(SRC, ["--simulate", "95,40", "--json"])
try:
    d = json.loads(out)
    check("--json is valid and decides CODEX-FIRST", d.get("mode") == "CODEX-FIRST", out[:200])
except ValueError as exc:
    check("--json is valid and decides CODEX-FIRST", False, str(exc))

print("=== both Claude windows must be readable before NORMAL ===")
os.environ["AI_USAGE_TRACKER_HOME"] = ENV["AI_USAGE_TRACKER_HOME"]
spec = importlib.util.spec_from_file_location("work_mode_under_test", SRC)
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
for label, usage in (("missing 5h", {"7d": 20.0, "5h": None}),
                     ("missing 7d", {"7d": None, "5h": 20.0})):
    verdict = wm.decide(usage, None, [])
    check(label + " is UNKNOWN", verdict.get("mode") == "UNKNOWN", repr(verdict))

shutil.rmtree(tmp, ignore_errors=True)
print("\n%d passed, %d failed" % (len(passes), len(fails)))
sys.exit(1 if fails else 0)
