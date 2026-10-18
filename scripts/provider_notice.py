"""
scripts/provider_notice.py
Builds the "notice" object that the provider scripts attach to an error or an
empty state, so the panel can tell the person what to do next.

Shape (every string is plain text, cleaned and bounded here, and again by the
panel before it is drawn):

    {
      "kind":    "setup" | "error" | "empty",
      "title":   "Not signed in to Azure",
      "message": "one or two sentences",
      "steps":   [{"label": "Sign in", "command": "az login"}],
      "footer":  "optional closing line"
    }

Security model: all text is FIXED by the provider scripts. The only value that
ever comes from outside is a kubectl context name, and it is accepted only when
it matches SAFE_NAME (so it can never carry shell syntax). The panel only
displays the commands and copies them to the clipboard; it never runs them.
"""

from __future__ import annotations

import re
from typing import Any

KINDS = ("setup", "error", "empty")

MAX_TITLE   = 80
MAX_MESSAGE = 240
MAX_STEPS   = 5
MAX_LABEL   = 60
MAX_COMMAND = 200
MAX_FOOTER  = 160

# A name that is safe to put inside a command shown to (and copied by) the person:
# no whitespace, quotes, "$", backticks, ";", "|", "&", "<", ">" or leading "-".
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@:+=/-]{0,127}$")

_CONTROL = re.compile(r"[\x00-\x1f\x7f]")


def _clean(value: Any, limit: int) -> str:
    text = _CONTROL.sub(" ", value if isinstance(value, str) else "")
    text = " ".join(text.split())
    return text[:limit]


def is_safe_name(value: Any) -> bool:
    return isinstance(value, str) and SAFE_NAME.match(value) is not None


def make_notice(kind: str, title: str, message: str = "",
                steps: list[tuple[str, str]] | None = None,
                footer: str = "") -> dict[str, Any]:
    """Return a bounded, plain-text notice. Unknown kinds become "error"."""
    out: dict[str, Any] = {
        "kind": kind if kind in KINDS else "error",
        "title": _clean(title, MAX_TITLE),
    }
    msg = _clean(message, MAX_MESSAGE)
    if msg:
        out["message"] = msg
    cleaned = []
    for label, command in (steps or [])[:MAX_STEPS]:
        cmd = _clean(command, MAX_COMMAND)
        if cmd:
            cleaned.append({"label": _clean(label, MAX_LABEL), "command": cmd})
    if cleaned:
        out["steps"] = cleaned
    foot = _clean(footer, MAX_FOOTER)
    if foot:
        out["footer"] = foot
    return out
