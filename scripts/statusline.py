#!/usr/bin/env python3
"""Codex usage reader for AI Usage Tracker — and an optional Claude Code status line.

    statusline.py --json     live per-account Codex read (what the widget runs)
    statusline.py --report   the same, human-readable (what `ai-usage` prints)
    statusline.py            Claude Code status line mode: reads the session JSON on stdin

    Opus 5 · my-project ⎇ main · ctx 34%
    Claude: 7d 61%; Codex A: 7d 100%*⚠; Codex B: 7d 0%

Everything it writes lives under $AI_USAGE_TRACKER_HOME (default ~/.ai-usage-tracker):
the account list (codex-accounts.json) and a cache of percentages. It never copies a
token anywhere; it reads each account's auth.json in place and sends the token only to
the two OpenAI hosts below, with redirects refused.

WHERE THE NUMBERS COME FROM
  Claude ...  Claude Code hands the status line `rate_limits.five_hour` and
              `rate_limits.seven_day` on stdin. Live, no extra work.
  Codex ...   LIVE, from the API: one minimal request to the Codex responses
              endpoint, whose response HEADERS carry `x-codex-primary-used-percent`
              and friends. The stream is abandoned the instant the headers land, so
              the probe costs a few tokens and no wall time. This is the only
              account-wide answer that exists — see below.
              FALLBACK, when there is no auth or no network: the `rate_limits`
              object Codex CLI writes into the newest session rollout JSONL under
              each CODEX_HOME. Always flagged `*`, because it is a floor, not a
              reading. Codex reports its windows positionally (`primary`/`secondary`)
              and which duration lands where varies, so the 7d figure is picked by
              `window_minutes`, never by slot.

WHY THE ROLLOUT SCRAPE IS ONLY A FALLBACK (measured 2026-08-01)
  The weekly quota is charged per ACCOUNT, but a rollout file is written only by the
  local `codex` CLI. Codex Cloud tasks, the Desktop app and the remote-control
  app-server spend the same quota and write no rollout here at all. Measured that
  day: account A's newest rollout said 32% while the API said 98% — the scrape had
  been frozen at the last CLI run for hours while the account was nearly spent, and
  the report cheerfully said "all accounts have headroom". A live read is not a
  refinement of the scrape; it is the difference between right and inverted.

ACCOUNTS (see CODEX_ACCOUNTS)
  One entry per Codex login, each in its own CODEX_HOME folder. The default list is just
  A = ~/.codex; add more from the widget's Accounts menu or by editing the JSON file.

TOKEN REFRESH (added 2026-08-09)
  Codex CLI renews its OAuth access token when you USE it, and nothing else does —
  `codex login status` only reads auth.json, it never validates the token. So an
  account left idle past the token's life silently goes stale and every live probe
  401s. Measured that day: account B's token expired on the 5th, its newest rollout
  was from the 3rd (outside the weekly window), and the report had been saying
  "no figure" for four days with nothing to say why. The live path now renews an
  expired token from the stored refresh token before probing, and retries once if
  the API rejects it anyway. When the refresh token itself is dead the report names
  the re-login command instead of shrugging.

MARKERS
  —   no figure at all: the live read failed AND no rollout carries a usable window
  *   NOT a live figure — the local CLI rollout fallback. It is a FLOOR: it cannot
      see Cloud, Desktop or app-server usage, so the account may be far further on.
  ⚠   at or above 85%

This script must never crash the status line: everything is wrapped, and a failure
degrades to the plain session line rather than printing a traceback.
"""

import fcntl
import json
import math
import os
import sys
import time
import urllib.request

HOME = os.path.expanduser("~")
# One folder holds this tool's config and cache. The override exists so the tests can run
# against a throwaway folder and never touch a real account list.
APP_HOME = os.path.expanduser(
    os.environ.get("AI_USAGE_TRACKER_HOME") or os.path.join(HOME, ".ai-usage-tracker"))

# label -> CODEX_HOME. The list lives in a config file rather than in this source, so the
# widget's Accounts menu can add and remove logins. Editing the file by hand works just as
# well; paths may be written "~/..." and are expanded on load.
ACCOUNTS_PATH = os.path.join(APP_HOME, "codex-accounts.json")
DEFAULT_ACCOUNTS = [
    ("A", os.path.join(HOME, ".codex")),
]


def load_accounts():
    """[(label, CODEX_HOME)] from the config file, or the defaults.

    A missing, malformed or unreadable file must NOT leave the status line — and every
    dispatch decision that reads it — with no accounts at all, so any failure falls back
    to the built-in default rather than to an empty list.
    """
    try:
        with open(ACCOUNTS_PATH) as fh:
            raw = json.load(fh)["accounts"]
        found = [(str(a["label"]), os.path.expanduser(str(a["home"])))
                 for a in raw if a.get("home") and a.get("label")]
        if found:
            return found
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return list(DEFAULT_ACCOUNTS)


def save_accounts(accounts):
    """Write the list back atomically — the widget and a session may both be editing."""
    payload = {"accounts": [{"label": label, "home": home.replace(HOME, "~")}
                            for label, home in accounts]}
    os.makedirs(APP_HOME, mode=0o700, exist_ok=True)
    tmp = "%s.tmp.%d" % (ACCOUNTS_PATH, os.getpid())
    with open(tmp, "w") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, ACCOUNTS_PATH)


CODEX_ACCOUNTS = load_accounts()
if not os.path.exists(ACCOUNTS_PATH):
    try:
        save_accounts(CODEX_ACCOUNTS)  # seed it, so there is something to edit
    except OSError:
        pass  # a read-only home must never break the status line

# widest "~/…" CODEX_HOME in the list above; the continuation rows indent to match
HOME_COL = max(len(h.replace(HOME, "~")) for _, h in CODEX_ACCOUNTS) + 1

CACHE_PATH = os.path.join(APP_HOME, "cache", "codex-usage.json")
CACHE_TTL = 20  # seconds; the status line re-renders far more often than Codex runs
TAIL_BYTES = 512 * 1024  # rollouts grow large; the last rate_limits is always near the end
RECENT_ROLLOUTS = 6  # how far back to look for a usable figure before giving up

# The live probe spends a little quota, so the status line never fires one itself: it
# reuses a live figure this recent and otherwise falls back to the free rollout scrape.
# `--report` always reads live — that is the whole point of asking.
LIVE_TTL = 15 * 60
CODEX_API = "https://chatgpt.com/backend-api/codex/responses"
CODEX_UA = "codex_cli_rs/0.145.0"
LIVE_TIMEOUT = 12
DEFAULT_MODEL = "gpt-5.6-sol"  # only used if models_cache.json is missing

# Renewing the access token: the Codex CLI's own OAuth client, so the refresh token
# stored in auth.json is accepted. Only the live path ever does this. The client ID is
# public (it ships inside every Codex CLI binary); it is an identifier, not a secret.
CODEX_OAUTH_URL = "https://auth.openai.com/oauth/token"
CODEX_OAUTH_CLIENT = "app_EMoamEEZ73f0CkXaXp7hrann"
TOKEN_SKEW = 5 * 60  # renew this far ahead of expiry, so a probe never races the clock
REFRESH_LOCK_TTL = 60  # a lock older than this belonged to a probe that died

WARN_AT = 60.0
ALERT_AT = 85.0

# Windows to display, in order. Dispatch advice below considers every reported window,
# including 5h even when the compact status line only displays the weekly one.
WINDOWS = ("7d",)

NO_COLOR = bool(os.environ.get("NO_COLOR"))


def c(text, code):
    if NO_COLOR or not code:
        return text
    return "\033[%sm%s\033[0m" % (code, text)


DIM = "2"
CYAN = "36"
BOLD = "1"


def pct_color(pct):
    if pct >= ALERT_AT:
        return "1;31"
    if pct >= WARN_AT:
        return "33"
    return "32"


def fmt_pct(pct):
    return ("%d%%" % round(pct)) if pct is not None else "—"


def fmt_window(minutes):
    """300 -> 5h, 10080 -> 7d."""
    if not minutes:
        return ""
    if minutes % 1440 == 0:
        return "%dd" % (minutes // 1440)
    if minutes % 60 == 0:
        return "%dh" % (minutes // 60)
    return "%dm" % minutes


def fmt_reset(epoch):
    if not epoch:
        return ""
    try:
        return time.strftime("%a %d %b %H:%M", time.localtime(epoch))
    except (ValueError, OSError, OverflowError, TypeError):
        return ""


def fmt_age(seconds):
    if seconds < 90:
        return "just now"
    if seconds < 5400:
        return "%dm ago" % (seconds // 60)
    if seconds < 172800:
        return "%dh ago" % (seconds // 3600)
    return "%dd ago" % (seconds // 86400)


def render_group(name, slots, stale=False):
    """`Claude: 7d 61%` — slots maps a window label ("5h", "7d") to a percentage.

    Every window in WINDOWS is printed, `—` when it has no usable figure, so the shape
    of the line stays identical whatever the providers happen to report.
    """
    parts = []
    for label in WINDOWS:
        pct = (slots.get(label) or {}).get("pct")
        if pct is None:
            parts.append("%s %s" % (label, c("—", DIM)))
            continue
        body = fmt_pct(pct)
        if stale:
            body += "*"
        if pct >= ALERT_AT:
            body += "⚠"
        parts.append("%s %s" % (label, c(body, pct_color(pct))))
    return "%s %s" % (c(name + ":", BOLD), ", ".join(parts))


# ---------------------------------------------------------------- codex reading

def recent_rollouts(codex_home, limit=RECENT_ROLLOUTS):
    """The most recent rollout-*.jsonl files under <home>/sessions/YYYY/MM/DD.

    Returns [(mtime, path)] newest first. More than one, because the newest rollout
    does not always carry a usable figure — an account whose premium quota is spent
    reports `limit_id: "premium"` with every window null, and the last real number
    is a few files back.
    """
    import glob

    sessions = os.path.join(codex_home, "sessions")
    if not os.path.isdir(sessions):
        return []
    days = sorted(
        glob.glob(os.path.join(sessions, "[0-9]" * 4, "[0-9]" * 2, "[0-9]" * 2)),
        reverse=True,
    )
    found = []
    for day in days[:5]:  # a day directory can exist but hold no rollouts yet
        try:
            entries = os.listdir(day)
        except OSError:
            continue
        for name in entries:
            if not (name.startswith("rollout-") and name.endswith(".jsonl")):
                continue
            path = os.path.join(day, name)
            try:
                found.append((os.path.getmtime(path), path))
            except OSError:
                continue
        if len(found) >= limit:
            break
    found.sort(reverse=True)
    return found[:limit]


def _match_object(text, start):
    """Return the JSON object starting at text[start] == '{', string-aware."""
    depth = 0
    in_str = False
    escaped = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_str:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None


def last_rate_limits(path):
    """The last non-null `rate_limits` object written to a rollout file."""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - TAIL_BYTES))
            blob = fh.read().decode("utf-8", "replace")
    except OSError:
        return None

    key = '"rate_limits":'
    idx = blob.rfind(key)
    while idx != -1:
        cursor = idx + len(key)
        while cursor < len(blob) and blob[cursor] in " \t":
            cursor += 1
        if cursor < len(blob) and blob[cursor] == "{":
            raw = _match_object(blob, cursor)
            if raw:
                try:
                    return json.loads(raw)
                except ValueError:
                    pass
        idx = blob.rfind(key, 0, idx)  # that one was null or malformed; keep walking back
    return None


MAX_EPOCH = 4102444800  # 2100-01-01: anything later is garbage, not a reset time
MAX_WINDOW_MINUTES = 366 * 1440


def clean_pct(raw):
    """A usage percentage as a finite float in 0..100, or None.

    Every figure here comes from outside this program (an HTTP header or a Codex log
    file). An `inf`, `nan` or 1e308 must not reach json.dumps (which would emit invalid
    JSON) or the widget (which converts it to an integer for display).
    """
    try:
        pct = float(raw)
    except (TypeError, ValueError, OverflowError):
        return None
    if not math.isfinite(pct):
        return None
    return min(100.0, max(0.0, pct))


def clean_epoch(raw):
    """A reset time as a plausible int epoch, or None."""
    try:
        epoch = int(float(raw))
    except (TypeError, ValueError, OverflowError):
        return None
    return epoch if 0 < epoch < MAX_EPOCH else None


def clean_minutes(raw):
    try:
        minutes = int(raw)
    except (TypeError, ValueError, OverflowError):
        return 0
    return minutes if 0 < minutes <= MAX_WINDOW_MINUTES else 0


def all_windows(rate_limits, now):
    """Every window still in force, as {"7d": {"pct": 100.0, "resets_at": 1785662338}}.

    Codex reports its windows positionally (`primary`/`secondary`) and which duration
    lands in which slot varies by plan and CLI version, so key off `window_minutes`
    rather than the slot name.
    """
    slots = {}
    if not isinstance(rate_limits, dict):
        return slots
    for slot in ("primary", "secondary"):
        win = rate_limits.get(slot)
        if not isinstance(win, dict):
            continue
        pct = clean_pct(win.get("used_percent"))
        if pct is None:
            continue
        resets_at = clean_epoch(win.get("resets_at"))
        # the window rolled over since this snapshot — the number no longer describes anything
        if resets_at and resets_at < now:
            continue
        label = fmt_window(clean_minutes(win.get("window_minutes")))
        if label:
            slots[label] = {"pct": pct, "resets_at": resets_at}
    return slots


# ------------------------------------------------------------------ live reading

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse every redirect. urllib copies request headers onto the redirected request —
    across hosts and even from https to plain http — so following one would hand the
    bearer token to whatever URL a 3xx names, or accept a forged token grant from it.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def token_expiry(token):
    """`exp` out of a JWT access token, or None if it does not carry a readable one."""
    import base64
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return float(json.loads(base64.urlsafe_b64decode(payload))["exp"])
    except Exception:
        return None


def _refresh_lock(path):
    """O_EXCL lock: two concurrent probes must not rotate each other's refresh token.

    The grant rotates the refresh token, so the loser of a race would write back a
    token the server has already retired. Whoever holds the lock refreshes; everyone
    else simply re-reads auth.json afterwards.
    """
    for _ in range(2):
        try:
            return os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            try:
                if time.time() - os.path.getmtime(path) <= REFRESH_LOCK_TTL:
                    return None
                os.unlink(path)  # a crashed probe must not wedge this forever
            except OSError:
                return None
        except OSError:
            return None
    return None


def write_private_json(path, data):
    """Replace `path` atomically with an owner-only (0600) file. True on success.

    The temp file is new and unique (O_EXCL) and never followed through a symlink
    (O_NOFOLLOW), so a planted `auth.json.tmp` link cannot redirect the tokens into
    another file, and a leftover temp file cannot lend auth.json looser permissions.
    """
    tmp = "%s.%d.%d.tmp" % (path, os.getpid(), time.monotonic_ns())
    try:
        fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    except OSError:
        return False
    try:
        with os.fdopen(fd, "w") as fh:
            os.fchmod(fh.fileno(), 0o600)  # umask cannot widen it, but be explicit
            json.dump(data, fh, indent=2)
        os.replace(tmp, path)  # auth.json is never half-written
        return True
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def codex_refresh(codex_home):
    """Trade the stored refresh token for a fresh access token, in place. Token or None.

    Returns None when the account has never logged in, when the refresh token itself
    has been revoked or expired (the caller then asks for a re-login), or when the
    network is unreachable — the three are not distinguished here because the caller's
    next probe distinguishes them for free.
    """
    path = os.path.join(codex_home, "auth.json")
    lock = os.path.join(codex_home, ".auth-refresh.lock")
    fd = _refresh_lock(lock)
    if fd is None:
        auth = codex_auth(codex_home)  # another probe is mid-refresh; take what it left
        return auth[0] if auth else None
    try:
        try:
            with open(path) as fh:
                stored = json.load(fh) or {}
        except (OSError, ValueError):
            return None
        tokens = stored.get("tokens") or {}
        if not tokens.get("refresh_token"):
            return None
        payload = json.dumps({
            "client_id": CODEX_OAUTH_CLIENT,
            "grant_type": "refresh_token",
            "refresh_token": tokens["refresh_token"],
            "scope": "openid profile email",
        }).encode()
        request = urllib.request.Request(CODEX_OAUTH_URL, data=payload, method="POST",
                                         headers={"Content-Type": "application/json",
                                                  "User-Agent": CODEX_UA})
        try:
            response = _OPENER.open(request, timeout=LIVE_TIMEOUT)
            granted = json.loads(response.read())
            response.close()
        except Exception:
            return None
        access = granted.get("access_token") if isinstance(granted, dict) else None
        if not isinstance(access, str) or not access:
            return None
        tokens["access_token"] = access
        for key in ("id_token", "refresh_token"):  # the grant rotates both; keep ours if absent
            if granted.get(key):
                tokens[key] = granted[key]
        stored["tokens"] = tokens
        stored["last_refresh"] = time.strftime("%Y-%m-%dT%H:%M:%S.000000Z", time.gmtime())
        write_private_json(path, stored)  # failure is fine: the token still works this run
        return access
    finally:
        os.close(fd)
        try:
            os.unlink(lock)
        except OSError:
            pass


def codex_auth(codex_home, allow_refresh=False):
    """(access_token, account_id) for a CODEX_HOME, or None if it has never logged in.

    With allow_refresh, a token already past `exp` (or within TOKEN_SKEW of it) is
    renewed first — the live path passes it, the status line never does, so a redraw
    still touches no network.
    """
    try:
        with open(os.path.join(codex_home, "auth.json")) as fh:
            tokens = (json.load(fh) or {}).get("tokens") or {}
    except (OSError, ValueError, AttributeError):
        return None
    token, account = tokens.get("access_token"), tokens.get("account_id")
    if not (token and account):
        return None
    if allow_refresh:
        expires = token_expiry(token)
        if expires is not None and expires - time.time() < TOKEN_SKEW:
            token = codex_refresh(codex_home) or token
    return (token, account)


def codex_model(codex_home):
    """A model slug this account can address — the probe is rejected without a real one."""
    try:
        with open(os.path.join(codex_home, "models_cache.json")) as fh:
            for entry in (json.load(fh) or {}).get("models") or []:
                if isinstance(entry, dict) and entry.get("slug"):
                    return entry["slug"]
    except (OSError, ValueError, AttributeError, TypeError):
        pass
    return DEFAULT_MODEL


def parse_live_headers(head):
    """`x-codex-primary-*` response headers -> the same {"7d": {...}} shape as the scrape."""
    slots = {}
    for slot in ("primary", "secondary"):
        pct = clean_pct(head.get("x-codex-%s-used-percent" % slot))
        minutes = clean_minutes(head.get("x-codex-%s-window-minutes" % slot))
        if pct is None or not minutes:  # an unused slot reports 0 minutes
            continue
        label = fmt_window(minutes)
        if not label:
            continue
        resets_at = clean_epoch(head.get("x-codex-%s-reset-at" % slot))
        slots[label] = {"pct": pct, "resets_at": resets_at}
    return slots


def live_windows(codex_home):
    """Ask the API what this ACCOUNT has actually spent -> (slots, reason).

    `slots` is None when it could not be reached, and `reason` then says which wall
    was hit — "no-auth", "expired" (re-login needed) or "unreachable" — so the report
    can say what to DO instead of printing a shrug.

    The rate-limit headers are attached only to an accepted request — a deliberately
    malformed one is rejected at validation and carries nothing (measured) — so this
    really does have to open a turn. We abandon the stream as soon as the headers are
    in hand, having read not a single token of the body.
    """
    import urllib.error

    auth = codex_auth(codex_home, allow_refresh=True)
    if not auth:
        return None, "no-auth"
    token, account = auth
    payload = json.dumps({
        "model": codex_model(codex_home),
        "instructions": "x",
        "input": [{"type": "message", "role": "user",
                   "content": [{"type": "input_text", "text": "."}]}],
        "stream": True,
        "store": False,
    }).encode()

    def probe(bearer):
        request = urllib.request.Request(CODEX_API, data=payload, method="POST", headers={
            "Authorization": "Bearer " + bearer,
            "chatgpt-account-id": account,
            "User-Agent": CODEX_UA,
            "originator": "codex_cli_rs",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "OpenAI-Beta": "responses=experimental",
        })
        try:
            response = _OPENER.open(request, timeout=LIVE_TIMEOUT)
            head = response.headers
            response.close()
            return head, 200
        except urllib.error.HTTPError as exc:
            head = exc.headers  # a 429 still reports the limits it is enforcing
            try:
                exc.close()
            except Exception:
                pass
            return head, exc.code
        except Exception:
            return None, None  # offline, DNS, TLS

    head, status = probe(token)
    if status == 401:
        # The stored expiry said the token was fine and the server disagrees — a
        # revoked or server-side-invalidated token. One renewal, then believe it.
        renewed = codex_refresh(codex_home)
        if renewed and renewed != token:
            head, status = probe(renewed)
    if head is None:
        return None, "unreachable"
    slots = parse_live_headers(head)
    if slots:
        return slots, None
    return None, ("expired" if status == 401 else "unreachable")


def read_codex_accounts(live=True):
    """One entry per account. `source` is "live", "rollout" or "none" — never guess."""
    now = time.time()
    out = []
    for label, home in CODEX_ACCOUNTS:
        entry = {"label": label, "home": home, "slots": {},
                 "stale": False, "age": None, "source": "none", "reason": None}
        slots, reason = live_windows(home) if live else (None, None)
        entry["reason"] = reason
        if slots:
            entry.update(slots=slots, age=0.0, source="live")
            out.append(entry)
            continue
        # Fallback: the local CLI rollouts. ALWAYS flagged stale, whatever its age —
        # it is blind to Cloud/Desktop/app-server usage, so it is a floor, not a reading.
        for mtime, path in recent_rollouts(home):
            limits = last_rate_limits(path)
            found = all_windows(limits, now) if limits else {}
            if found:
                entry.update(slots=found, age=now - mtime, stale=True, source="rollout")
                break
        out.append(entry)
    return out


def cache_load():
    """{"live": {at, accounts}, "rollout": {at, accounts}} — either slot may be absent."""
    try:
        with open(CACHE_PATH) as fh:
            cached = json.load(fh)
        return cached if isinstance(cached, dict) else {}
    except (OSError, ValueError):
        return {}


def cache_store(kind, accounts, now):
    """Write one slot, preserving the other — a live read must survive a status-line redraw.

    Several readers often run at once (widget, CLI, status lines), and preserving "the other slot" is a
    read-modify-write: unlocked, two writers each read the file, each keeps the OTHER slot as
    it was at read time, and the second write silently discards the first writer's fresh slot.
    The temp file was also a single shared path, so one process's os.replace could publish
    another's half-written file. Both are fixed here: the whole load-modify-replace runs under
    an exclusive lock, and the temp name is per-process.
    """
    try:
        os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True)
        fd = os.open(CACHE_PATH + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    except OSError:
        return  # a read-only or racing cache must never break the line
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except OSError:
            return
        cached = cache_load()
        cached[kind] = {"at": now, "accounts": accounts}
        cached.pop("at", None)  # drop the pre-2026-08-01 single-slot shape
        cached.pop("accounts", None)
        tmp = "%s.tmp.%d" % (CACHE_PATH, os.getpid())
        try:
            with open(tmp, "w") as fh:
                json.dump(cached, fh)
            os.replace(tmp, CACHE_PATH)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    finally:
        os.close(fd)


def codex_accounts_cached():
    """The status-line path — it NEVER probes the API. A redraw must not spend quota.

    It shows the last live figure while that is recent, and otherwise the free rollout
    scrape, marked `*`. `codex-usage` / `--report` is what refreshes the live number.
    """
    now = time.time()
    cached = cache_load()

    live = cached.get("live") or {}
    if live.get("accounts") and now - live.get("at", 0) < LIVE_TTL:
        age = now - live["at"]
        return [dict(a, age=age if a.get("source") == "live" else a.get("age"))
                for a in live["accounts"]]

    rollout = cached.get("rollout") or {}
    if rollout.get("accounts") and now - rollout.get("at", 0) < CACHE_TTL:
        return rollout["accounts"]

    accounts = read_codex_accounts(live=False)
    cache_store("rollout", accounts, now)
    return accounts


# ---------------------------------------------------------------- session line

def git_branch(cwd):
    """Read .git/HEAD directly — cheaper than shelling out on every redraw."""
    path = cwd
    for _ in range(12):
        dot = os.path.join(path, ".git")
        if os.path.isdir(dot):
            head = os.path.join(dot, "HEAD")
        elif os.path.isfile(dot):  # worktree: .git is a file pointing at the real gitdir
            try:
                with open(dot) as fh:
                    gitdir = fh.read().strip().split("gitdir:", 1)[-1].strip()
            except OSError:
                return None
            if not os.path.isabs(gitdir):
                gitdir = os.path.join(path, gitdir)
            head = os.path.join(gitdir, "HEAD")
        else:
            parent = os.path.dirname(path)
            if parent == path:
                return None
            path = parent
            continue
        try:
            with open(head) as fh:
                ref = fh.read().strip()
        except OSError:
            return None
        if ref.startswith("ref: refs/heads/"):
            return ref[len("ref: refs/heads/"):]
        return ref[:7]  # detached HEAD
    return None


def build_lines(data):
    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or os.getcwd()
    model = (data.get("model") or {}).get("display_name") or "claude"

    first = [c(model, CYAN), c(os.path.basename(cwd.rstrip("/")) or "/", BOLD)]

    branch = git_branch(cwd)
    if branch:
        first.append(c("⎇ " + branch, DIM))

    ctx = (data.get("context_window") or {}).get("used_percentage")
    if isinstance(ctx, (int, float)):
        first.append("ctx " + c(fmt_pct(float(ctx)), pct_color(float(ctx))))

    limits = data.get("rate_limits") or {}
    claude_slots = {}
    for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
        win = limits.get(key)
        if isinstance(win, dict) and win.get("used_percentage") is not None:
            claude_slots[label] = {
                "pct": float(win["used_percentage"]), "resets_at": win.get("resets_at"),
            }

    groups = []
    # absent on API-key billing and on older Claude Code builds
    if any(label in claude_slots for label in WINDOWS):
        groups.append(render_group("Claude", claude_slots))
    for account in codex_accounts_cached():
        groups.append(render_group(
            "Codex " + account["label"], account.get("slots") or {}, account.get("stale", False)
        ))

    lines = [" · ".join(first)]
    if groups:
        lines.append(c("; ", DIM).join(groups))
    return lines


def dispatch_advice(accounts):
    """Which account to dispatch to — the one line this whole report exists to produce.

    Shared by `--report` and `--json` so the terminal and the desktop widget can never
    disagree about it. Returns {"level", "text", "home"} where level is
    ok | warn | exhausted | stale | unknown.

    Headroom means STRICTLY UNDER 100% — Codex is used until
    the budget actually runs out. ⚠ (≥ ALERT_AT) is a warning to expect mid-run exhaustion
    and have Claude ready to take over a dying worker; it is never, by itself, a reason
    not to dispatch.
    """
    def worst(a):
        values = [slot["pct"] for slot in a["slots"].values()
                  if slot.get("pct") is not None]
        return max(values) if values else 100.0

    pressured = sorted({a["label"] for a in accounts
                        if any((slot.get("pct") or 0) >= ALERT_AT
                               for slot in a["slots"].values())})
    # LIVE ONLY. A `*` rollout figure is a floor with no bound on its error, so never
    # dispatch on one — so it must never reach a "Dispatch with…" line either.
    # (When both a recommendation and a `*` caveat were printed, the recommendation is
    # what got read.)
    usable = sorted(
        (a for a in accounts
         if a["slots"] and a.get("source") == "live" and worst(a) < 100.0),
        key=worst,
    )
    if not usable and any(a["slots"] and a["stale"] for a in accounts):
        return {"level": "stale", "home": None, "account": None, "pressured": pressured,
                "text": "No LIVE figure for any account — nothing here is dispatchable"
                        " evidence. Re-run when the API is reachable; never dispatch on a"
                        " `*` scrape (it cannot see Cloud/Desktop usage)."}
    if usable:
        best = usable[0]
        home = best["home"].replace(HOME, "$HOME")
        text = 'Dispatch with CODEX_HOME="%s" (account %s, %d%% used).' % (
            home, best["label"], int(worst(best)))
        if pressured:
            text += (" ⚠ %s at or above %d%% — expect it to run out mid-task."
                     % (", ".join(pressured), int(ALERT_AT)))
        return {"level": "warn" if pressured else "ok", "home": home, "text": text,
                "account": best["label"], "pct": int(worst(best)), "pressured": pressured}
    if any(a["slots"] and a.get("source") == "live" for a in accounts):
        return {"level": "exhausted", "home": None, "account": None, "pressured": pressured,
                "text": "Every account is at 100% — Codex is exhausted; Claude executes"
                        " until a window resets."}
    return {"level": "unknown", "home": None, "account": None, "pressured": pressured,
            "text": "No account could be read at all — status UNKNOWN, not exhausted."
                    " Do not dispatch on a guess."}


def report():
    """Human-readable Codex usage — backs `codex-usage` and the /codex-usage skill.

    Reads LIVE from the API, bypassing the cache: this is an explicit, on-demand check,
    usually run precisely because someone is about to dispatch work and needs the real
    answer. It refreshes the cache the status line reads.
    """
    now = time.time()
    accounts = read_codex_accounts(live=True)
    if any(a["source"] == "live" for a in accounts):
        cache_store("live", accounts, now)
    print(c("Codex usage", BOLD) + c(" — live from the API, per account", DIM))
    # Stamp the run: the report is often pasted into a session or a handoff, where
    # "when was this read?" decides whether the figures still mean anything.
    print(c("  run " + time.strftime("%a %d %b %Y %H:%M:%S %Z", time.localtime(now)), DIM))
    print()

    # A dead login is the one failure that never heals on its own, and it hides behind
    # a `*` rollout figure just as happily as behind a `—`. Collect it either way.
    relogin = [a for a in accounts if a.get("reason") in ("expired", "no-auth")]

    stale_seen = False
    for account in accounts:
        prefix = "  %s  %s" % (c(account["label"], BOLD), account["home"].replace(HOME, "~").ljust(HOME_COL))
        slots = account["slots"]
        if not slots:
            why = {
                "expired": "LOGIN EXPIRED — re-login below; no rollout has a usable window either",
                "no-auth": "never logged in — see below",
                "unreachable": "no figure — API unreachable and no rollout has a usable window",
            }.get(account.get("reason"),
                  "no figure — live read failed and no rollout has a usable window")
            print(prefix + c(why, "1;31" if account.get("reason") == "expired" else DIM))
            continue
        labels = [w for w in WINDOWS if w in slots] + sorted(w for w in slots if w not in WINDOWS)
        for label in labels:
            pct = slots[label]["pct"]
            body = fmt_pct(pct) + ("*" if account["stale"] else "")
            stale_seen = stale_seen or account["stale"]
            row = prefix + "%s %s" % (label, c(body.rjust(6), pct_color(pct)))
            if pct >= ALERT_AT:
                row += c("  ⚠", "1;31")
            tail = []
            if slots[label].get("resets_at"):
                tail.append("resets " + fmt_reset(slots[label]["resets_at"]))
            if account["source"] == "live":
                tail.append("live")
            elif account.get("age") is not None:
                tail.append("last CLI run " + fmt_age(account["age"]))
            if tail:
                row += c("   " + "   ".join(tail), DIM)
            print(row)
            prefix = " " * (5 + HOME_COL)  # label the account on its first row only

    print()
    advice = dispatch_advice(accounts)
    print(c(advice["text"], "32") if advice["level"] == "ok"
          else c("⚠ " + advice["text"], "1;31"))
    if stale_seen:
        print(c("* NOT live — local CLI rollout fallback, a floor only. It cannot see Codex", DIM))
        print(c("  Cloud, Desktop or app-server usage, so the account may be far further on.", DIM))
    for account in relogin:
        print(c('⚠ Account %s cannot be read: its login is dead and the stored refresh token'
                ' could not renew it.' % account["label"], "1;31"))
        print(c('  Fix: CODEX_HOME="%s" codex login'
                % account["home"].replace(HOME, "$HOME"), "1;31"))


def report_json():
    """Machine-readable twin of `report()` — backs the desktop usage widget.

    Same LIVE read and the same cache write, so a widget poll doubles as the refresh
    that work-mode.py and the status line then reuse (they honour LIVE_TTL), instead
    of each of them opening its own turn against the API.
    """
    now = time.time()
    accounts = read_codex_accounts(live=True)
    if any(a["source"] == "live" for a in accounts):
        cache_store("live", accounts, now)
    print(json.dumps({
        "at": now,
        "warn_at": WARN_AT,
        "alert_at": ALERT_AT,
        "accounts": [dict(a, home=a["home"].replace(HOME, "~")) for a in accounts],
        "dispatch": dispatch_advice(accounts),
    }, default=str))


def main():
    if "--json" in sys.argv[1:]:
        report_json()
        return
    if "--report" in sys.argv[1:]:
        report()
        return
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        data = {}
    try:
        print("\n".join(build_lines(data)))
    except Exception:  # a broken status line is worse than a bare one
        cwd = (data.get("workspace") or {}).get("current_dir") or os.getcwd()
        model = (data.get("model") or {}).get("display_name") or "claude"
        print("%s · %s" % (model, os.path.basename(cwd.rstrip("/")) or "/"))


if __name__ == "__main__":
    main()
