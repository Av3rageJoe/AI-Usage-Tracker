#!/usr/bin/env python3
"""dispatch_advice() is the one line the whole usage report exists to produce, and it is
now read by two consumers (`--report` and the desktop widget's `--json`). These are the
cases that must never regress — above all: a `*` scrape NEVER yields a "Dispatch with"
line, because the recommendation is what gets read.

    /usr/bin/python3 tests/dispatch_advice_test.py
"""
import os
import sys

os.environ.setdefault("AI_USAGE_TRACKER_HOME",
                      __import__("tempfile").mkdtemp(prefix="aiut-dispatch-"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
from statusline import dispatch_advice  # noqa: E402

H = os.path.expanduser("~")


def acct(label, home, pct, source="live", stale=False, extra=None):
    slots = {"7d": {"pct": pct, "resets_at": None}} if pct is not None else {}
    if extra is not None:
        slots["5h"] = {"pct": extra, "resets_at": None}
    return {"label": label, "home": os.path.join(H, home), "slots": slots,
            "stale": stale, "source": source, "reason": None}


def main():
    a = dispatch_advice([acct("A", ".codex", 40.0), acct("B", ".codex-alt", 10.0)])
    assert a["level"] == "ok" and a["account"] == "B" and "account B, 10%" in a["text"], a

    a = dispatch_advice([acct("A", ".codex", 40.0), acct("B", ".codex-alt", 90.0)])
    assert a["level"] == "warn" and a["account"] == "A", a
    assert a["pressured"] == ["B"] and "B at or above 85%" in a["text"], a

    a = dispatch_advice([acct("A", ".codex", 20.0, source="rollout", stale=True)])
    assert a["level"] == "stale" and "Dispatch with" not in a["text"], a

    a = dispatch_advice([acct("A", ".codex", 100.0), acct("B", ".codex-alt", 100.0)])
    assert a["level"] == "exhausted", a

    a = dispatch_advice([acct("A", ".codex", None, source="none")])
    assert a["level"] == "unknown", a

    # 7d clear but the 5h window is spent: worst() is 100, so it is NOT dispatchable.
    a = dispatch_advice([acct("A", ".codex", 10.0, extra=100.0)])
    assert a["level"] == "exhausted", a

    print("dispatch_advice: 6/6 pass")


if __name__ == "__main__":
    main()
