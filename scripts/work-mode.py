#!/usr/bin/env python3
"""Claude's own usage window, and the budget MODE the widget shows under it.

  NORMAL       Claude under 90% used on both windows.
  CODEX-FIRST  Claude >= 90% AND a Codex account has every window under 80%: move work there.
  NO-RELIEF    Claude >= 90% and no Codex account has that headroom.
  UNKNOWN      A window that decides the mode could not be read. Never treated as NORMAL.
  CHECK-BROKEN The check itself crashed (exit 3).

WHERE THE NUMBERS COME FROM
  Claude ...  GET https://api.anthropic.com/api/oauth/usage with the OAuth token from the
              login Keychain item. It is the same endpoint the CLI's own /usage uses
              ("fetchUtilization: GET /api/oauth/usage"), it is a plain read, and it costs
              NO tokens — so it can run on every refresh, free. It DOES
              rate-limit, though (429 + `retry-after`, measured at 84s and at 3600s), so
              the figure is cached for CLAUDE_TTL and shared by every reader.
              The token is read, used for this one request, and never stored or logged.
  Codex ...   statusline.py's live reader, imported rather than reimplemented. A cached
              LIVE figure under 15 minutes old is reused, so several readers starting
              together probe once, not five times.

NOT GETTING RATE-LIMITED IN THE FIRST PLACE (measured 2026-09-03 08:16)
  One morning the report said UNREADABLE and every reader got MODE: UNKNOWN for a full
  hour. The chain, and the three defects it exposed — each now fixed and covered by
  tests/work_mode_usage_test.py:

    1. Three readers started in the same second and each fired its own live read.
       There was no single-flight lock, so bursty starts were the normal case.
       -> claude_lock(): ONE process reads, the rest wait briefly for its cached answer.
    2. All three got http-401 (the OAuth token was mid-refresh). Only a 429 set a cooldown,
       so all three retried within seconds — and that burst is what earned the 429.
       -> EVERY failure now earns one (CLAUDE_FAIL_COOLDOWN for anything but a 429).
    3. The 429 carried `retry-after: 3600`, and the cached figure was thrown away whole
       because the 5h window had rolled over — even though the 7d number was still good.
       -> with_resets_applied(): a rolled-over window is 0%, and only THAT window.

  And the backstop, because a lockout can still outlast everything we cache: honouring
  `retry-after` to the second is right while we have a figure to serve, but sitting blind
  for an hour is its own failure. With nothing to report, one probe per CLAUDE_BLIND_RETRY
  is made anyway — it recovered a live figure on the first try the day this was written.

ONE PARSING TRAP, MEASURED THE DAY THIS WAS WRITTEN
  The response also carries a `limits[]` array, and on 2026-08-16 it held a *scoped* entry
  at 100% ("weekly_scoped", model Fable) while the account itself was at 75%. Taking the
  max of that array would have thrown every session into CODEX-FIRST on a limit that
  binds a model we never use. Only `seven_day.utilization` and `five_hour.utilization`
  are ever read here.

RELIEF NEEDS A *LIVE* CODEX FIGURE
  A `*` rollout scrape is a floor with no bound on its error (statusline.py's header
  explains why: it cannot see Cloud/Desktop/app-server spend — measured 32% against a
  real 98%). So a stale figure can never grant relief; without a live read the mode is
  NO-RELIEF, and it says why.

USAGE
  work-mode.py --json                  the decision as JSON (what the widget runs)
  work-mode.py --report                human-readable: both budgets and the verdict
  work-mode.py --simulate 90 --report  force Claude's 7d figure (no network)
  work-mode.py --simulate 90,29,100    force Claude 7d, then Codex account figures in order
"""
import datetime
import fcntl
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
APP_HOME = os.path.expanduser(
    os.environ.get("AI_USAGE_TRACKER_HOME") or os.path.join(HOME, ".ai-usage-tracker"))

# statusline.py already knows how to read Codex live, refresh a dead token and cache the
# answer. Import it (it is installed beside this file) instead of growing a second copy.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import statusline as sl
except Exception:  # a status-line bug must not take the budget check with it
    sl = None

# ---- thresholds ----------------------------------------------------------------------
CLAUDE_TRIP = 90.0    # Claude at/above this = start conserving
CODEX_RELIEF = 80.0   # a Codex account strictly under this = relief is real

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE = "Claude Code-credentials"
# Claude Code keeps its login here instead of the Keychain on some setups.
CRED_FILE = os.path.join(HOME, ".claude", ".credentials.json")
CLAUDE_TIMEOUT = 10
CLAUDE_UA = "claude-cli (external, cli)"

# The endpoint IS rate-limited, and session starts are bursty — measured 2026-08-16, a
# handful of starts plus a few manual checks earned an HTTP 429 within minutes. So the
# figure is cached and SHARED by every reader:
CLAUDE_CACHE = os.path.join(APP_HOME, "cache", "claude-usage.json")
CLAUDE_LOCK = os.path.join(APP_HOME, "cache", "claude-usage.lock")
CLAUDE_TTL = 120          # a fresh read serves every session start for this long
CLAUDE_STALE_MAX = 30 * 60  # older than this and it stops being worth deciding on
CLAUDE_COOLDOWN = 5 * 60  # after a 429 with no retry-after, wait this long
# EVERY failure earns a cooldown, not just the 429. Measured 2026-09-03 08:16: three
# session starts in the same second each got an http-401 (token mid-refresh), and because
# a 401 set NO cooldown they all retried within seconds. That burst turned a transient 401
# into a 429 carrying `retry-after: 3600` — an hour of MODE: UNKNOWN off one blip.
CLAUDE_FAIL_COOLDOWN = 60
# A server lockout can outlast CLAUDE_STALE_MAX (measured retry-after: 3600 > 1800), so the
# normal staleness rule GUARANTEES UNKNOWN for the whole lockout. While we are locked out,
# an old figure — reported with its age — beats no figure at all.
CLAUDE_LOCKOUT_STALE_MAX = 6 * 60 * 60
# Only one process on this machine does the live read; the rest wait briefly for its answer
# instead of firing their own request. Bursty session starts are what earn the 429.
CLAUDE_LOCK_WAIT = 3.0
# "Do not hammer" and "sit blind for an hour" are different things. When the cooldown has a
# usable cached figure to serve, we honour `retry-after` to the second. When it does NOT —
# we are reporting UNKNOWN and the session is being told to stop and ask — one probe every
# CLAUDE_BLIND_RETRY is not abuse of an endpoint, and an hour of UNKNOWN is its own failure.
CLAUDE_BLIND_RETRY = 10 * 60
# A slightly old Claude figure is still the real account-wide number — unlike the Codex
# rollout scrape, which is blind to whole surfaces. So stale-but-recent DOES decide the
# mode here; it is only reported with its age so nobody mistakes it for a live read.

# ------------------------------------------------------------------ Claude usage

def claude_token():
    """The OAuth access token, from the Keychain item the login writes (file as fallback)."""
    raw = None
    try:
        # Absolute path: a hook must not let whatever is on PATH answer for the Keychain.
        out = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=10,
        )
        if out.returncode == 0 and out.stdout.strip():
            raw = out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    if raw is None:
        try:
            with open(CRED_FILE) as fh:
                raw = fh.read()
        except OSError:
            return None, "no-credentials"
    try:
        data = json.loads(raw)
    except ValueError:
        return None, "unreadable-credentials"
    oauth = data.get("claudeAiOauth") or data
    token = oauth.get("accessToken")
    return (token, None) if token else (None, "no-token")


def with_resets_applied(usage, now):
    """A cached figure with every ROLLED-OVER window set back to 0% — per window, not all.

    A window whose reset time has passed did not become unknown; it restarted at zero. The
    old code returned "any window has reset" and the caller then discarded the WHOLE cached
    figure, so a 5h rollover threw away a perfectly good 7d number. Measured 2026-09-03:
    an hour of MODE: UNKNOWN during a 429 lockout with `7d 21%` sitting unused in the cache
    purely because the 5h window had turned over at 03:20.

    The residual error is spend accrued since the rollover, bounded by how long we have been
    locked out, and it is the fail-open direction this check already accepts elsewhere.
    """
    out = dict(usage)
    for key, stamp_key in (("7d", "resets_7d"), ("5h", "resets_5h")):
        stamp = usage.get(stamp_key)
        if not isinstance(stamp, str):
            continue
        try:  # "2026-08-21T00:00:00.000000+00:00"
            when = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        except (ValueError, TypeError, OverflowError):
            continue
        if when.timestamp() <= now:
            out[key] = 0.0
            out[stamp_key] = None
            out.setdefault("reset_windows", []).append(key)
    return out


LOCK_BUSY = "busy"   # someone else is mid-read; wait for THEIR answer, do not add a request


def claude_lock():
    """A held lock handle, LOCK_BUSY if another process is reading, or None if unlockable.

    flock, not an O_EXCL marker file: the kernel drops it when the holder exits, so a
    session killed mid-read cannot wedge every later one behind a stale lock file.
    None (no .cache dir, read-only home) FAILS OPEN — an unusable lock must never be the
    reason the budget goes unread.
    """
    try:
        os.makedirs(os.path.dirname(CLAUDE_LOCK), exist_ok=True)
        fh = open(CLAUDE_LOCK, "a+")
    except OSError:
        return None
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.close()
        return LOCK_BUSY
    except Exception:
        fh.close()
        return None
    return fh


def claude_unlock(fh):
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
    except OSError:
        pass
    try:
        fh.close()
    except OSError:
        pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse every redirect — the Authorization header must never travel to a new host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def claude_cache_load():
    try:
        with open(CLAUDE_CACHE) as fh:
            cached = json.load(fh)
        return cached if isinstance(cached, dict) else {}
    except (OSError, ValueError):
        return {}


def claude_cache_store(cached):
    try:
        os.makedirs(os.path.dirname(CLAUDE_CACHE), exist_ok=True)
        # PID in the temp name: sessions run concurrently, and two writers sharing one
        # temp path can interleave their bytes and then publish the mangled result.
        tmp = "%s.%d.tmp" % (CLAUDE_CACHE, os.getpid())
        with open(tmp, "w") as fh:
            json.dump(cached, fh)
        os.replace(tmp, CLAUDE_CACHE)  # atomic: a reader never sees a half-written file
    except OSError:
        pass


def claude_usage():
    """{"7d", "5h", "resets_7d", "age", "stale"} or (None, reason). Costs no tokens.

    Cached and shared across sessions, because the endpoint rate-limits (429) and every
    session start asks. A cached figure inside CLAUDE_TTL is served without any HTTP at
    all; after a 429 we stop asking for CLAUDE_COOLDOWN and serve the cached one.
    """
    now = time.time()

    def read_cache(at_least=None):
        """(usage_with_resets_applied|None, age, cooldown_until) from the shared cache."""
        c = claude_cache_load()
        u = c.get("usage") if isinstance(c.get("usage"), dict) else None
        at = c.get("at", 0)
        if at_least is not None and at <= at_least:
            u = None          # not the newer answer we are waiting for
        a = time.time() - at
        if u and a < 0:
            # A figure from the future (clock rollback) is not fresh.
            u, a = None, 0
        return (with_resets_applied(u, time.time()) if u else None,
                a, c.get("cooldown_until", 0))

    cached = claude_cache_load()
    have, age, cooldown_until = read_cache()

    def served(stale):
        return dict(have, age=age, stale=stale), None

    def best_effort(reason, lockout):
        """Serve what we have rather than reporting UNKNOWN, when it is still worth it."""
        limit = CLAUDE_LOCKOUT_STALE_MAX if lockout else CLAUDE_STALE_MAX
        if have and age < limit:
            return served(True)
        return None, reason

    if have and age < CLAUDE_TTL:
        return served(False)
    # The cooldown binds even with NO cached figure — otherwise the very case that earns a
    # 429 (a burst of session starts, nothing cached yet) has every one of them retrying.
    blind_probe = False
    if now < cooldown_until:
        served_stale = best_effort("rate-limited — cooling down as the endpoint asked", True)
        if served_stale[0] is not None:
            return served_stale        # we have something to say; honour retry-after fully
        # Nothing to serve: we would report UNKNOWN. Probe at most once per window.
        if now - cached.get("last_attempt", 0) < CLAUDE_BLIND_RETRY:
            return served_stale
        blind_probe = True

    lock = claude_lock()
    if lock == LOCK_BUSY:
        # Wait a moment for the winner's answer instead of firing a second request at an
        # endpoint that rate-limits on exactly this pattern.
        deadline = now + CLAUDE_LOCK_WAIT
        while time.time() < deadline:
            time.sleep(0.15)
            winner, w_age, w_cool = read_cache(at_least=now - age)
            if winner:
                return dict(winner, age=w_age, stale=False), None
            if w_cool > time.time():
                break  # the winner hit a wall; waiting longer buys nothing
        have, age, cooldown_until = read_cache()
        return best_effort("another session is reading the usage endpoint",
                           cooldown_until > time.time())

    claude_cache_store(dict(cached, last_attempt=now))
    try:
        fresh, reason, retry_after = claude_fetch()
    finally:
        if lock is not None:
            claude_unlock(lock)
    cached = dict(cached, last_attempt=now)

    if fresh:
        claude_cache_store({"at": time.time(), "usage": fresh})
        return dict(fresh, age=0.0, stale=False), None
    # EVERY failure earns a cooldown, not only the 429. A 401 (token mid-refresh) used to
    # set none, so every session start retried within seconds and the burst is what turned
    # one transient 401 into an hour-long 429 (measured 2026-09-03 08:16).
    if reason == "http-429":
        # The endpoint tells us exactly how long to wait (measured: 84s, and 3600s).
        wait = retry_after or CLAUDE_COOLDOWN
    else:
        wait = CLAUDE_FAIL_COOLDOWN
    # A blind probe keeps the LONGER of the two deadlines — it may not shorten a lockout the
    # endpoint already asked for, and it may not stack a fresh hour on top of it either.
    until = time.time() + wait
    if blind_probe:
        until = max(until, cooldown_until)
    claude_cache_store(dict(cached, cooldown_until=until))
    return best_effort(reason, reason == "http-429")


def claude_fetch():
    """One live read of the usage endpoint. -> (usage|None, reason|None, retry_after_secs)."""
    token, reason = claude_token()
    if not token:
        return None, reason, 0
    req = urllib.request.Request(USAGE_URL, headers={
        "Authorization": "Bearer " + token,
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": CLAUDE_UA,
        "Accept": "application/json",
    })
    # Never follow a redirect: urllib copies headers onto the redirected request, which
    # would hand the OAuth bearer token to whatever host the 3xx names.
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(req, timeout=CLAUDE_TIMEOUT) as resp:
            body = json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        # 401 = the stored token has expired. Claude Code renews it on its own; we never
        # try to, because a botched refresh would break the login this session runs on.
        try:
            retry = int(float(exc.headers.get("retry-after") or 0))
        except (AttributeError, TypeError, ValueError):
            retry = 0
        return None, "http-%s" % exc.code, retry
    except Exception as exc:
        return None, "unreachable (%s)" % type(exc).__name__, 0

    def window(key):
        # ONLY these two fields — never limits[], see the module docstring.
        slot = body.get(key)
        if isinstance(slot, dict) and isinstance(slot.get("utilization"), (int, float)):
            return float(slot["utilization"]), slot.get("resets_at")
        return None, None

    seven, seven_reset = window("seven_day")
    five, five_reset = window("five_hour")
    missing = [name for name, value in (("7d", seven), ("5h", five)) if value is None]
    if missing:
        return None, "missing-%s-window-in-response" % "-and-".join(missing), 0
    return {"7d": seven, "5h": five,
            "resets_7d": seven_reset, "resets_5h": five_reset}, None, 0


# ------------------------------------------------------------------- Codex usage

def codex_accounts(force=None):
    """([{label, home, windows, live}], unknown_reason|None) — windows is {"7d": pct, ...}."""
    if force is not None:
        pairs = sl.CODEX_ACCOUNTS if sl else [("A", "~/.codex")]
        return [{"label": label, "home": home, "windows": {"7d": pct}, "live": True}
                for (label, home), pct in zip(pairs, force)], None
    if sl is None:
        return [], "statusline.py could not be imported"

    now = time.time()
    cached = (sl.cache_load().get("live") or {})
    if cached.get("accounts") and now - cached.get("at", 0) < sl.LIVE_TTL:
        accounts = cached["accounts"]
    else:
        accounts = sl.read_codex_accounts(live=True)
        if any(a.get("source") == "live" for a in accounts):
            sl.cache_store("live", accounts, now)

    out = []
    for a in accounts:
        slots = a.get("slots") or {}
        out.append({
            "label": a.get("label"), "home": a.get("home"),
            # EVERY window Codex reports, not just the weekly one: an account can sit under
            # 80% for the week and still be spent for the next five hours.
            "windows": {w: v.get("pct") for w, v in slots.items() if v.get("pct") is not None},
            # A rollout scrape is a floor, not a reading — it can never grant relief.
            "live": a.get("source") == "live",
        })
    return out, None


# ---------------------------------------------------------------------- decision

def worst_window(account):
    """The window closest to spent — an account is only usable if EVERY window is."""
    return max(account["windows"].values()) if account.get("windows") else None


def decide(claude, claude_reason, codex, codex_unknown=None):
    """The whole policy, in one place."""
    if claude is None:
        # NOT "NORMAL": an unreadable budget is unknown, and calling it normal is how a
        # dead check hides. The session is told to resolve it before doing anything big.
        return {"mode": "UNKNOWN", "codex": codex, "claude": None,
                "why": "Claude usage could not be read (%s)" % claude_reason}

    seven, five = claude.get("7d"), claude.get("5h")
    missing = [w for w, pct in (("7d", seven), ("5h", five)) if pct is None]
    if missing:
        return {"mode": "UNKNOWN", "codex": codex, "claude": claude,
                "why": "Claude %s usage could not be read" % " + ".join(missing)}
    tripped = [w for w, pct in (("7d", seven), ("5h", five))
               if pct is not None and pct >= CLAUDE_TRIP]
    base = {"claude": claude, "tripped": tripped}

    if not tripped:
        return dict(base, mode="NORMAL", codex=codex,
                    why="Claude 7d %s%% used — under the %s%% trip"
                        % (fmt(seven), int(CLAUDE_TRIP)))

    if codex_unknown:
        return dict(base, mode="UNKNOWN", codex=codex,
                    why="Claude %s at/above %s%% but %s"
                        % (" + ".join(tripped), int(CLAUDE_TRIP), codex_unknown))

    relief = sorted(
        (a for a in codex if a["live"] and a["windows"]
         and all(p < CODEX_RELIEF for p in a["windows"].values())),
        key=worst_window,
    )
    if relief:
        return dict(base, mode="CODEX-FIRST", codex=codex, account=relief[0],
                    why="Claude %s at/above %s%%; Codex %s at %s%% used"
                        % (" + ".join(tripped), int(CLAUDE_TRIP),
                           relief[0]["label"], fmt(worst_window(relief[0]))))

    if not any(a["live"] for a in codex):
        detail = "no live Codex figure (a `*` scrape can never grant relief)"
    else:
        detail = "no Codex account with every window under %s%% (%s)" % (
            int(CODEX_RELIEF),
            ", ".join("%s %s" % (a["label"], describe_windows(a)) for a in codex)
            or "none readable")
    return dict(base, mode="NO-RELIEF", codex=codex,
                why="Claude %s at/above %s%%; %s"
                    % (" + ".join(tripped), int(CLAUDE_TRIP), detail))


def describe_windows(account):
    if not account.get("windows"):
        return "no figure"
    mark = "" if account.get("live") else "*"
    return " ".join("%s %s%%%s" % (w, fmt(p), mark)
                    for w, p in sorted(account["windows"].items()))


def fmt(pct):
    return "?" if pct is None else ("%g" % round(float(pct)))


# ---------------------------------------------------------------------- surfaces

def age_text(seconds):
    """"8h 4m" / "42m" / "50s" — a 6h-old figure must not be reported as "cached 484m ago"."""
    seconds = max(0, int(seconds))
    if seconds < 90:
        return "%ds" % seconds
    minutes = seconds // 60
    if minutes < 60:
        return "%dm" % minutes
    return "%dh %dm" % (minutes // 60, minutes % 60)


def stale_note(claude):
    """The one sentence that stops a stale figure being read as a live one."""
    if not claude or not claude.get("stale"):
        return ""
    note = " [cached %s ago — the endpoint would not answer" % age_text(claude.get("age", 0))
    reset = claude.get("reset_windows") or []
    if reset:
        note += "; %s window%s reset since, counted as 0%%" % (
            " + ".join(reset), "" if len(reset) == 1 else "s")
    return note + "]"


def run(force_claude=None, force_codex=None):
    if force_claude is not None:
        claude, reason = {"7d": force_claude, "5h": force_claude,
                          "resets_7d": None, "resets_5h": None}, None
    else:
        claude, reason = claude_usage()

    # Codex is probed ONLY when Claude has actually tripped — it keeps the common case
    # free (a Codex live read spends a few Codex tokens).
    tripped = claude is not None and any(
        claude.get(w) is not None and claude[w] >= CLAUDE_TRIP for w in ("7d", "5h"))
    codex, unknown = codex_accounts(force=force_codex) if tripped else ([], None)
    d = decide(claude, reason, codex, unknown)
    # A stale figure must say so wherever the verdict travels — --json consumers see
    # only `why`, never the report's row.
    note = stale_note(d.get("claude"))
    if note:
        d["why"] = d["why"] + note
        d["stale"] = True
    return d


def report(d):
    def paint(text, code):
        return text if (sl is None or sl.NO_COLOR) else "\033[%sm%s\033[0m" % (code, text)

    claude = d.get("claude")
    print(paint("Budget", "1") + paint("  — Claude live, Codex live when Claude has tripped", "2"))
    print()
    if claude:
        for label, key in (("7d", "7d"), ("5h", "5h")):
            pct = claude.get(key)
            if pct is None:
                continue
            colour = "1;31" if pct >= CLAUDE_TRIP else ("33" if pct >= 60 else "32")
            row = "  %s  %s %s" % (paint("Claude", "1"), label,
                                   paint(("%s%%" % fmt(pct)).rjust(6), colour))
            if pct >= CLAUDE_TRIP:
                row += paint("  ⚠", "1;31")
            if claude.get("stale"):
                why = ("   cached %s ago (the endpoint would not answer)"
                       % age_text(claude.get("age", 0)))
                if key in (claude.get("reset_windows") or []):
                    why = "   window reset since — counted as 0%"
                row += paint(why, "2")
            print(row)
    else:
        print("  " + paint("Claude    UNREADABLE — %s" % d["why"], "1;31"))
    for a in d.get("codex") or []:
        worst = worst_window(a)
        colour = "1;31" if (worst is not None and worst >= CODEX_RELIEF) else "32"
        print("  %s  %s" % (paint("Codex " + (a["label"] or "?"), "1"),
                            paint(describe_windows(a), colour)))
    if not d.get("codex") and d["mode"] == "NORMAL" and claude:
        print("  " + paint("Codex     not probed — Claude has not tripped %d%%" % int(CLAUDE_TRIP), "2"))
    print()
    colour = {"NORMAL": "32", "CODEX-FIRST": "1;31",
              "NO-RELIEF": "1;31", "UNKNOWN": "33"}[d["mode"]]
    print(paint("MODE: %s — %s" % (d["mode"], d["why"]), colour))


def main():
    args = sys.argv[1:]
    force_claude = force_codex = None
    if "--simulate" in args:
        # Caller misuse is its own failure class: exit 2, distinct from a broken check (3).
        try:
            raw = args[args.index("--simulate") + 1].split(",")
            force_claude = float(raw[0])
            if len(raw) > 1:
                force_codex = [float(x) for x in raw[1:]]
        except (IndexError, ValueError):
            sys.stderr.write("work-mode: --simulate needs CLAUDE_PCT[,CODEX_PCT...]\n")
            sys.exit(2)

    d = run(force_claude, force_codex)
    if "--json" in args:
        print(json.dumps(d, indent=2, default=str))
    else:
        report(d)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        # "Unknown is not normal": a crashed check must never look like a quiet NORMAL.
        detail = "%s: %s" % (type(exc).__name__, exc)
        if "--json" in sys.argv[1:]:
            print(json.dumps({"mode": "CHECK-BROKEN", "error": detail}))
        else:
            sys.stderr.write("work-mode: CHECK-BROKEN — %s\n" % detail)
        sys.exit(3)
