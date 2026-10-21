#!/usr/bin/env python3
"""Proof that ONE transient 401 can no longer blank the work mode for an hour.

Reconstructs a measured failure: three readers started in the same
second each fired their own live read, got http-401 (token mid-refresh), and — because a
401 set no cooldown — retried within seconds. That burst earned a 429 carrying
`retry-after: 3600`, and the cached figure was discarded wholesale because the 5h window
had rolled over. Result: the report said UNREADABLE and every reader got MODE: UNKNOWN
for a full hour, with a perfectly good `7d 21%` sitting unused in the cache.

Runs against a COPY of the real script with a fake cache dir; no network, no Keychain.
"""
import datetime, importlib.util, os, shutil, sys, tempfile, time

os.environ["AI_USAGE_TRACKER_HOME"] = tempfile.mkdtemp(prefix="wmhome-")
SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "work-mode.py")
fails, passes = [], []


def check(name, cond, detail=""):
    (passes if cond else fails).append(name)
    print(("  \033[32m✓\033[0m " if cond else "  \033[31m✗\033[0m ") + name
          + (("  — " + str(detail)) if detail and not cond else ""))


def wipe(wm):
    for path in (wm.CLAUDE_CACHE, wm.CLAUDE_LOCK):
        try:
            os.remove(path)
        except OSError:
            pass


def fresh_module(tmp):
    """A private copy of the module with its cache pointed at a scratch dir."""
    spec = importlib.util.spec_from_file_location("wm_%d" % time.time_ns(), SRC)
    wm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(wm)
    wm.CLAUDE_CACHE = os.path.join(tmp, "claude-usage.json")
    wm.CLAUDE_LOCK = os.path.join(tmp, "claude-usage.lock")
    wm.LOG = os.path.join(tmp, "work-mode.log")
    return wm


def iso(offset_seconds):
    return datetime.datetime.fromtimestamp(
        time.time() + offset_seconds, datetime.timezone.utc).isoformat()


def stub(wm, *results):
    """Feed claude_fetch a scripted sequence; record how many requests were actually made."""
    box = {"calls": 0}
    seq = list(results)

    def fake():
        box["calls"] += 1
        return seq[min(box["calls"] - 1, len(seq) - 1)]

    wm.claude_fetch = fake
    return box


OK = ({"7d": 40.0, "5h": 3.0, "resets_7d": iso(86400), "resets_5h": iso(3600)}, None, 0)
UNAUTHORISED = (None, "http-401", 0)
LIMITED = (None, "http-429", 3600)

tmp = tempfile.mkdtemp(prefix="wmusage-")
try:
    # ---------------------------------------------------------------- 1. the 401 storm
    print("=== a transient 401 must not become an hour-long 429 ===")
    wm = fresh_module(tmp)
    box = stub(wm, UNAUTHORISED)
    u1, r1 = wm.claude_usage()
    check("first read reports the 401", u1 is None and r1 == "http-401", r1)
    u2, r2 = wm.claude_usage()
    u3, r3 = wm.claude_usage()
    check("a 401 sets a cooldown, so the next starts send NO request",
          box["calls"] == 1, "%d requests" % box["calls"])
    check("the cooled-down sessions still report a reason", u2 is None and u3 is None)

    # ------------------------------------------------- 2. one lock, not three requests
    print("\n=== concurrent starts do a single live read ===")
    wipe(wm)
    wm = fresh_module(tmp)
    box = stub(wm, OK)
    held = wm.claude_lock()
    check("the lock is acquired by the winner", hasattr(held, "fileno"))
    other = fresh_module(tmp)
    other_box = stub(other, OK)
    other.CLAUDE_LOCK_WAIT = 0.4
    t0 = time.time()
    u, r = other.claude_usage()
    check("a loser sends no request of its own while the winner holds the lock",
          other_box["calls"] == 0, "%d requests" % other_box["calls"])
    check("the loser gives up quickly, it does not block the session start",
          time.time() - t0 < 2.0, "%.1fs" % (time.time() - t0))
    check("the loser says who is reading, it never claims NORMAL",
          u is None and "another session" in (r or ""), r)
    wm.claude_unlock(held)

    # --------------------------------------- 3. a 5h rollover keeps the 7d figure alive
    print("\n=== a rolled-over window is 0%, not a reason to bin the whole figure ===")
    wm = fresh_module(tmp)
    now = time.time()
    rolled = {"7d": 21.0, "5h": 1.0, "resets_7d": iso(3600), "resets_5h": iso(-7200)}
    applied = wm.with_resets_applied(rolled, now)
    check("the rolled-over 5h window reads 0%", applied["5h"] == 0.0, applied["5h"])
    check("the 7d figure SURVIVES the 5h rollover", applied["7d"] == 21.0, applied["7d"])
    check("the reset window is named for the report",
          applied.get("reset_windows") == ["5h"], applied.get("reset_windows"))
    both = wm.with_resets_applied(
        {"7d": 99.0, "5h": 99.0, "resets_7d": iso(-60), "resets_5h": iso(-60)}, now)
    check("a rolled-over 7d window stops asserting 99% into a new week",
          both["7d"] == 0.0 and both["5h"] == 0.0, both)

    # ---------------------------------------- 4. the whole 2026-09-03 sequence, end to end
    print("\n=== the measured failure, replayed end to end ===")
    wipe(wm)
    wm = fresh_module(tmp)
    wm.claude_cache_store({"at": time.time() - 4 * 3600, "usage": rolled})
    box = stub(wm, LIMITED)
    usage, reason = wm.claude_usage()
    check("a 4h-old figure is served through the lockout instead of UNKNOWN",
          usage is not None and usage["7d"] == 21.0, reason)
    check("and it is flagged stale, never passed off as a live read",
          bool(usage and usage.get("stale")))
    d = wm.decide(usage, reason, [])
    check("the mode is decided, not UNKNOWN", d["mode"] == "NORMAL", d["mode"])
    check("the verdict itself carries the staleness",
          "cached" in wm.stale_note(usage), wm.stale_note(usage))
    check("the verdict names the reset window",
          "5h window reset" in wm.stale_note(usage), wm.stale_note(usage))

    # ------------------------------------------- 5. blind + locked out still probes once
    print("\n=== blind for an hour is its own failure ===")
    wipe(wm)
    wm = fresh_module(tmp)
    wm.claude_cache_store({"at": 0, "cooldown_until": time.time() + 3600,
                           "last_attempt": time.time() - 3600})
    box = stub(wm, OK)
    usage, reason = wm.claude_usage()
    check("with nothing to serve, one probe is made despite the cooldown",
          box["calls"] == 1 and usage is not None, "%d requests" % box["calls"])
    check("and it recovers the real figure", usage and usage["7d"] == 40.0)

    wipe(wm)
    wm = fresh_module(tmp)
    wm.claude_cache_store({"at": 0, "cooldown_until": time.time() + 3600,
                           "last_attempt": time.time() - 60})
    box = stub(wm, OK)
    wm.claude_usage()
    wm.claude_usage()
    check("but the probe is rate-limited to one per CLAUDE_BLIND_RETRY",
          box["calls"] == 0, "%d requests" % box["calls"])

    wipe(wm)
    wm = fresh_module(tmp)
    long_lockout = time.time() + 3600
    wm.claude_cache_store({"at": 0, "cooldown_until": long_lockout,
                           "last_attempt": time.time() - 3600})
    stub(wm, LIMITED)
    wm.claude_usage()
    after = wm.claude_cache_load().get("cooldown_until", 0)
    check("a failed blind probe never shortens the lockout the endpoint asked for",
          after >= long_lockout - 1, "%.0f vs %.0f" % (after, long_lockout))

    # --------------------------------------------------- 6. a usable figure obeys retry-after
    wipe(wm)
    wm = fresh_module(tmp)
    wm.claude_cache_store({"at": time.time() - 600, "usage": rolled,
                           "cooldown_until": time.time() + 3600,
                           "last_attempt": time.time() - 3600})
    box = stub(wm, OK)
    usage, _ = wm.claude_usage()
    check("with a figure to serve, retry-after is honoured to the second (no probe)",
          box["calls"] == 0 and usage is not None, "%d requests" % box["calls"])

    # ------------------------------------------- 6b. an expired login is never sent
    print("\n=== an expired login is reported, never sent (it only earns 401s, then a 429) ===")
    import json as _json, subprocess as _sp
    wipe(wm)
    wm = fresh_module(tmp)
    net = {"calls": 0}

    class _NoNet:
        def open(self, *a, **k):
            net["calls"] += 1
            raise RuntimeError("the network must not be touched")

    wm.urllib.request.build_opener = lambda *a: _NoNet()

    def keychain_holds(expires_ms):
        secret = _json.dumps({"claudeAiOauth": {"accessToken": "a", "refreshToken": "r",
                                                "expiresAt": expires_ms}})
        wm.subprocess.run = lambda *a, **k: _sp.CompletedProcess(a, 0, stdout=secret, stderr="")

    keychain_holds(int((time.time() - 3600) * 1000))
    token, why = wm.claude_token()
    check("an expired login is not handed out", token is None, token)
    check("the reason says how to renew it", bool(why) and "`claude -p hi`" in why, why)
    usage, reason = wm.claude_usage()
    check("and no request is made with it", usage is None and net["calls"] == 0,
          "%d requests" % net["calls"])
    cool = wm.claude_cache_load().get("cooldown_until", 0) - time.time()
    check("a local expiry gets the short cooldown, so a renewal shows up soon",
          0 < cool <= wm.CLAUDE_FAIL_COOLDOWN + 1, cool)
    keychain_holds(int((time.time() + 3600) * 1000))
    check("a valid login is handed out unchanged", wm.claude_token() == ("a", None))

    wipe(wm)
    wm = fresh_module(tmp)
    stub(wm, UNAUTHORISED)
    wm.claude_usage()
    cool = wm.claude_cache_load().get("cooldown_until", 0) - time.time()
    check("a server 401 pauses for CLAUDE_AUTH_COOLDOWN, not one minute",
          cool > wm.CLAUDE_FAIL_COOLDOWN + 1, cool)

    # ------------------------------------------------------------------ 7. age wording
    print("\n=== a 6h-old figure must not be reported as \"484m ago\" ===")
    check("age_text renders hours", wm.age_text(29126) == "8h 5m", wm.age_text(29126))
    check("age_text renders minutes", wm.age_text(2400) == "40m", wm.age_text(2400))
    check("age_text renders seconds", wm.age_text(30) == "30s", wm.age_text(30))
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print("\n%d passed, %d failed" % (len(passes), len(fails)))
if fails:
    print("FAILED: " + "; ".join(fails))
sys.exit(1 if fails else 0)
