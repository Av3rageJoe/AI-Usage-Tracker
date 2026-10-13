#!/usr/bin/env python3
"""Proof of the security properties of the token-handling code in statusline.py.

  1. A redirect never carries the Codex bearer token (or the refresh request) to another
     host — including a downgrade to plain http. A CONTROL run with plain urllib shows the
     leak this guards against is real, so the test cannot pass against unfixed code.
  2. A refreshed auth.json is written owner-only (0600), atomically, and a planted
     symlink at the old fixed temp name is never followed.
  3. Hostile numbers in rate-limit headers are rejected or clamped, and the --json
     output stays valid JSON.

Everything runs against local HTTP servers on 127.0.0.1 and a throwaway folder. No real
login is read and nothing leaves this machine.
"""
import base64, http.server, importlib.util, json, os, shutil, stat, sys, tempfile
import threading, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SL_PATH = os.path.join(HERE, "..", "scripts", "statusline.py")
tmp = tempfile.mkdtemp(prefix="aiut-sec-")
os.environ["AI_USAGE_TRACKER_HOME"] = os.path.join(tmp, "app-home")
fails, passes = [], []


def check(name, cond, detail=""):
    (passes if cond else fails).append(name)
    print(("  \033[32m✓\033[0m " if cond else "  \033[31m✗\033[0m ") + name
          + (("  — " + str(detail)) if detail and not cond else ""))


def load_sl():
    spec = importlib.util.spec_from_file_location("sl_under_test", SL_PATH)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def server(handler_body):
    """Start a local HTTP server; handler_body(handler) answers every request."""
    seen = []

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _any(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            seen.append({"method": self.command, "path": self.path,
                         "auth": self.headers.get("Authorization"), "body": body})
            handler_body(self)

        do_GET = do_POST = _any

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, seen


def jwt(exp):
    payload = base64.urlsafe_b64encode(json.dumps({"exp": exp}).encode()).decode().rstrip("=")
    return "h." + payload + ".s"


def codex_home(name, token, refresh="refresh-secret"):
    home = os.path.join(tmp, name)
    os.makedirs(home)
    with open(os.path.join(home, "auth.json"), "w") as fh:
        json.dump({"tokens": {"access_token": token, "account_id": "acct",
                              "refresh_token": refresh}}, fh)
    return home


# ------------------------------------------------------------- 1. redirects
print("=== 1. a redirect never carries a token to another host ===")


def thief_reply(h):
    h.send_response(200)
    h.send_header("Content-Type", "application/json")
    h.end_headers()
    h.wfile.write(b'{"access_token": "attacker-token"}')


thief, stolen = server(thief_reply)
thief_url = "http://127.0.0.1:%d/collect" % thief.server_address[1]


def redirector_reply(h):
    h.send_response(302)
    h.send_header("Location", thief_url)
    h.end_headers()


redirector, _ = server(redirector_reply)
redirect_url = "http://127.0.0.1:%d/api" % redirector.server_address[1]

# CONTROL: plain urllib (what the code used before) does forward the bearer token.
try:
    urllib.request.urlopen(urllib.request.Request(
        redirect_url, data=b"{}", method="POST",
        headers={"Authorization": "Bearer control-secret"}), timeout=5).close()
except Exception:
    pass
check("control: plain urllib DOES leak the bearer across a redirect",
      any(r["auth"] == "Bearer control-secret" for r in stolen), stolen)
stolen.clear()

sl = load_sl()
sl.CODEX_API = redirect_url
sl.CODEX_OAUTH_URL = redirect_url
home = codex_home("probe", jwt(4102444000))
slots, reason = sl.live_windows(home)
check("the live probe refuses the redirect", slots is None and reason == "unreachable",
      (slots, reason))
check("the bearer token never reached the redirect target", not stolen, stolen)

stolen.clear()
home = codex_home("refresh", jwt(1))  # expired: forces a refresh first
before = open(os.path.join(home, "auth.json")).read()
token = sl.codex_refresh(home)
check("the token refresh refuses the redirect", token is None, token)
check("the refresh never reached the redirect target", not stolen, stolen)
check("auth.json is untouched by a refused refresh",
      open(os.path.join(home, "auth.json")).read() == before)

# ------------------------------------------------------- 2. auth.json writes
print("\n=== 2. a refreshed auth.json is private and symlink-safe ===")


def oauth_reply(h):
    h.send_response(200)
    h.send_header("Content-Type", "application/json")
    h.end_headers()
    h.wfile.write(json.dumps({"access_token": jwt(4102444000), "refresh_token": "rotated",
                              "id_token": "id"}).encode())


oauth, calls = server(oauth_reply)
sl.CODEX_OAUTH_URL = "http://127.0.0.1:%d/oauth/token" % oauth.server_address[1]
home = codex_home("write", jwt(1))
victim = os.path.join(tmp, "victim.txt")
open(victim, "w").write("untouched")
os.symlink(victim, os.path.join(home, "auth.json.tmp"))  # the old, fixed temp name
old_umask = os.umask(0)  # the loosest umask: the file must still come out 0600
try:
    token = sl.codex_refresh(home)
finally:
    os.umask(old_umask)
auth_path = os.path.join(home, "auth.json")
mode = stat.S_IMODE(os.lstat(auth_path).st_mode)
saved = json.load(open(auth_path))
check("the refresh succeeded against the local OAuth server", bool(token), calls)
check("the refresh token went in the POST body, not the URL",
      calls and calls[0]["method"] == "POST" and b"refresh-secret" in calls[0]["body"]
      and "refresh-secret" not in calls[0]["path"], calls)
check("auth.json is 0600 even under umask 000", mode == 0o600, oct(mode))
check("auth.json is a regular file, not a symlink", not os.path.islink(auth_path))
check("auth.json holds the rotated tokens", saved["tokens"]["refresh_token"] == "rotated")
check("the planted symlink target was never written", open(victim).read() == "untouched")
strays = [f for f in os.listdir(home) if f.endswith(".tmp") and f != "auth.json.tmp"]
check("no temp files left behind", not strays, strays)

# --------------------------------------------------------- 3. hostile numbers
print("\n=== 3. hostile figures are rejected or clamped ===")
bad = {"x-codex-primary-used-percent": "inf", "x-codex-primary-window-minutes": "10080",
       "x-codex-secondary-used-percent": "nan", "x-codex-secondary-window-minutes": "300"}
check("inf and nan percentages are dropped", sl.parse_live_headers(bad) == {},
      sl.parse_live_headers(bad))
huge = {"x-codex-primary-used-percent": "1e400", "x-codex-primary-window-minutes": "10080"}
check("an overflowing percentage is dropped", sl.parse_live_headers(huge) == {})
over = {"x-codex-primary-used-percent": "150", "x-codex-primary-window-minutes": "10080",
        "x-codex-primary-reset-at": "1e30",
        "x-codex-secondary-used-percent": "-7", "x-codex-secondary-window-minutes": "99999999999"}
parsed = sl.parse_live_headers(over)
check("an out-of-range percentage is clamped to 100",
      parsed.get("7d", {}).get("pct") == 100.0, parsed)
check("an absurd reset time is dropped", parsed.get("7d", {}).get("resets_at") is None, parsed)
check("an absurd window length is dropped", list(parsed) == ["7d"], parsed)
check("the clamped result serialises as strict JSON",
      bool(json.dumps(parsed, allow_nan=False)))
check("a rollout with junk figures yields nothing, not a crash",
      sl.all_windows({"primary": {"used_percent": "abc", "window_minutes": 10080},
                      "secondary": {"used_percent": 1e999, "window_minutes": "x"}}, 0) == {})
check("fmt_reset survives an absurd epoch", sl.fmt_reset(10 ** 30) == "")

for srv in (thief, redirector, oauth):
    srv.shutdown()
shutil.rmtree(tmp, ignore_errors=True)
print("\n%d passed, %d failed" % (len(passes), len(fails)))
sys.exit(1 if fails else 0)
