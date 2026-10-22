# AI Usage Tracker

## What it does

Shows, on the macOS desktop and in the menu bar, how much of each Codex account's usage
windows (7-day, plus 5-hour when reported) and Claude Code's 7-day and 5-hour windows is spent,
plus a MODE verdict (NORMAL / CODEX-FIRST / NO-RELIEF / UNKNOWN). The same figures are
available in a terminal (`ai-usage`) and, optionally, as a Claude Code status line.

## How it works

- `src/usage-widget.swift` — AppKit accessory app. Every 300 s (and on wake) it runs
  `/usr/bin/python3 $APP_HOME/statusline.py --json`, then `work-mode.py --json`, with a
  clean environment, and draws the result: one borderless panel per display at desktop
  level + 1, and an `NSStatusItem` chip. It also edits the two account lists under a
  `flock` transaction lock and launches sign-ins (`codex login --device-auth` in the
  background, or `codex login` / `claude auth login|logout` in Terminal via a private
  one-use `.command` file whose exit status comes back through a 0600 sentinel file).
- `scripts/statusline.py` — Codex reader. Per account it reads `<CODEX_HOME>/auth.json`,
  renews an expiring access token with the stored refresh token (O_EXCL lock in the
  CODEX_HOME so two readers never rotate it twice), sends one minimal streaming request to
  `chatgpt.com/backend-api/codex/responses`, and reads `x-codex-{primary,secondary}-*`
  headers. Fallback when that fails: the last `rate_limits` in recent rollout logs, marked
  stale (`*`). Results are cached in `$APP_HOME/cache/codex-usage.json` (live slot 15 min,
  rollout slot 20 s) under a lock.
- `scripts/work-mode.py` — Claude reader + verdict. Reads the Claude Code OAuth token
  from the Keychain (`/usr/bin/security`, fallback `~/.claude/.credentials.json`), calls
  `api.anthropic.com/api/oauth/usage` (free), caches 120 s with single-flight `flock`,
  per-failure cooldowns and `retry-after`, then `decide()` computes the MODE. Codex is
  consulted only when Claude is at/above 90 %.
- `install.sh` copies the scripts into `~/.ai-usage-tracker` (0700), builds and ad-hoc
  signs the app into `~/Applications`, and registers a LaunchAgent.

## Why it's built this way

- The widget holds no credentials and parses no provider data itself: one reader per
  provider, shared by the widget, CLI and status line, so all three always agree.
- Codex usage is read live because the rollout logs only see local CLI use (measured 32 %
  vs a real 98 %). A live read costs a few tokens, so the status line never probes; only
  the widget/CLI do, and they refresh the shared cache.
- Rejected: storing tokens in the app's own Keychain item (a second copy to leak and keep
  in sync); following redirects (urllib forwards `Authorization` cross-host and to http);
  a test-only tool-directory override inside the installed app; tests that back up and
  restore the real account list (a killed test loses it — tests use a throwaway
  `AI_USAGE_TRACKER_HOME` instead).

## Invariants

- Tokens are sent only to `chatgpt.com`, `auth.openai.com` (Codex) and `api.anthropic.com`
  (Claude), over HTTPS, with redirects refused. Tokens are never cached, logged or printed.
- `auth.json` is only ever rewritten atomically, 0600, via an O_EXCL|O_NOFOLLOW temp file.
- Folders the widget creates for accounts are 0700. Existing folders are never chmodded.
- An account is appended to a list only after its sign-in finished (exit 0, and for Codex
  an `auth.json` exists). Removing an account never deletes its folder.
- Every number from outside (headers, logs, script JSON) is finite-checked and clamped
  before display; the widget never converts an unchecked Double to Int.
- A `*` (non-live) Codex figure never yields a dispatch recommendation or relief.
- UNKNOWN is never shown as NORMAL; a crashed check exits 3 with CHECK-BROKEN.
- A Claude token past its `expiresAt` is never sent (it only earns 401s, then a 429);
  the reason names `claude -p hi`. This tool never renews or rewrites the Claude login.
- Sign-in and sign-out for the default Claude account run with `CLAUDE_CONFIG_DIR`
  cleared: set, even to `~/.claude`, it makes Claude Code store the login in a different
  Keychain item ("Claude Code-credentials-<sha256(dir)[:8]>") that nothing reads.

## Where to look

- Paths and the `AI_USAGE_TRACKER_HOME` override: top of each of the three source files.
- Token handling: `statusline.py` `_NoRedirect`, `write_private_json`, `codex_refresh`,
  `live_windows`; `work-mode.py` `claude_token`, `claude_fetch`.
- Input validation: `statusline.py` `clean_pct` / `clean_epoch` / `clean_minutes`;
  `usage-widget.swift` `cleanPct`, `resetText`.
- Sign-in launchers: `usage-widget.swift` `makeAuthLauncher`, `DeviceLogin`, `launchAuth`.
- Tests: `tests/run.sh` (builds, then runs all); `tests/security_test.py` covers redirects,
  `auth.json` writes and hostile numbers.

## Known gaps

- Uses provider endpoints that are not documented for third parties; they may change.
- The token refresh can race the Codex CLI's own refresh of the same account (refresh-token
  rotation); the lock only serialises this tool's readers.
- A hung reader (e.g. a stalled network read inside the per-request timeout) delays the
  next refresh until it exits; there is no whole-fetch watchdog.

## Changelog

- 2026-10-22 — Every reported window gets a row: a 5h row hidden at 0% looked like a
  missing window rather than a free one.
- 2026-10-21 — Claude usage stopped after a day in the desktop app: the CLI's Keychain
  token expired (only a running `claude` renews it), 401s escalated to a 429, and a
  re-login from the widget landed in a hashed Keychain item. Expired tokens are no longer
  sent, 401/403 pause 10 min, and default-account sign-in clears `CLAUDE_CONFIG_DIR`.

- 2026-10-13 — First public release: security audit fixes (redirect refusal, private
  `auth.json` writes, 0700 account folders, input clamping, test seam confined to the bare
  binary), self-contained `~/.ai-usage-tracker` layout, hermetic tests.
