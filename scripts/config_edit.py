#!/usr/bin/python3
"""
scripts/config_edit.py
Edit the plugin's settings from the panel: Azure DevOps targets, GitHub
repositories, Kubernetes contexts and namespaces, and development.mockData. Nothing else can be written.

    config_edit.py preview '<changes JSON>'   validate and show what would change; writes NOTHING
    config_edit.py apply   '<changes JSON>'   validate again, keep config.json.bak, write once
    config_edit.py contexts                   list the kubectl contexts (read-only)

The changes are ONE JSON argument (at most 16 KB), any subset of:

    { "azureDevOps": { "targets": [ { "organization": "https://dev.azure.com/x", "project": "p" } ] },
      "github":      { "repos": [ "owner/repo" ] },
      "kubernetes":  { "contexts": [ "name" ], "allContexts": false,
                       "namespaces": [ "ns" ], "excludeNamespaces": [ "ns" ] },
      "development": { "mockData": false } }

Every value is checked with the SAME rules the provider scripts use when they
run (so a saved value can never be rejected later), the number of entries is
capped like theirs, duplicates are refused, and unknown keys are refused. Keys
of config.json that are not listed above (refresh, notifications, development.mockError,
your own) are kept exactly as they are.

Output (one JSON object on stdout):
    preview: { "ok": true, "changed": bool, "reformat": bool, "truncated": bool,
               "diff": [ { "t": "+" | "-" | " ", "s": "line" } ] }
    apply:   { "ok": true, "changed": bool }
    contexts:{ "ok": true, "contexts": [str], "current": str }
    errors:  { "ok": false, "errors": [ { "field": "azureDevOps.targets.1.project", "message": "..." } ] }
             { "ok": false, "error": "short plain-text reason" }

The file is rewritten with standard formatting (2-space JSON, same key order).
Where the file lives, the safety rules and the migration are in config_store.py.
"""
from __future__ import annotations

import copy
import difflib
import json
import re
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import config_store  # noqa: E402
from config_store import ConfigError  # noqa: E402
import azure_devops as az  # noqa: E402
import github_actions as gh  # noqa: E402
import kubernetes as k8s  # noqa: E402  (imported last: its signal handler kills kubectl)

MAX_ARG_BYTES   = 16 * 1024
MAX_DIFF_LINES  = 120
MAX_CONTEXT_LIST = 100
CONTEXT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@=+,~#-]{0,252}$")
_CONTROL = re.compile(r"[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁠-⁤⁦-⁯﻿]")

ALLOWED = {
    "azureDevOps": {"targets"},
    "github":      {"repos"},
    "kubernetes":  {"contexts", "allContexts", "namespaces", "excludeNamespaces"},
    "development": {"mockData"},
}


def emit(payload: dict) -> int:
    print(json.dumps(payload))
    return 0 if payload.get("ok") else 1


def fail(message: str) -> int:
    return emit({"ok": False, "error": _CONTROL.sub(" ", str(message))[:200] or "Could not change the settings"})


# ── Validation ────────────────────────────────────────────────────────────────

class _Errors:
    def __init__(self) -> None:
        self.items: list[dict] = []

    def add(self, field: str, message: str) -> None:
        if len(self.items) < 50:
            self.items.append({"field": field, "message": message})


def _text(value: Any) -> str | None:
    return value.strip() if isinstance(value, str) else None


def _string_list(value: Any, field: str, errs: _Errors, limit: int, label: str,
                 valid, message: str, fold: bool = False) -> list[str] | None:
    if not isinstance(value, list):
        errs.add(field, "Must be a list")
        return None
    if len(value) > limit:
        errs.add(field, f"At most {limit} {label}")
        return None
    out: list[str] = []
    seen: set[str] = set()
    for i, raw in enumerate(value):
        item = _text(raw)
        name = f"{field}.{i}"
        if item is None or item == "":
            errs.add(name, "Required")
            continue
        if not valid(item):
            errs.add(name, message)
            continue
        key = item.lower() if fold else item
        if key in seen:
            errs.add(name, "Listed twice")
            continue
        seen.add(key)
        out.append(item)
    return out


def validate(changes: Any) -> tuple[dict, list[dict]]:
    """Return (clean_changes, errors). clean_changes holds only what was asked for."""
    errs = _Errors()
    clean: dict[str, dict] = {}
    if not isinstance(changes, dict):
        errs.add("", "The changes must be an object")
        return clean, errs.items
    for section, body in changes.items():
        if section not in ALLOWED:
            errs.add(str(section)[:60], "This setting cannot be edited here")
            continue
        if not isinstance(body, dict):
            errs.add(section, "Must be an object")
            continue
        out: dict[str, Any] = {}
        for key, value in body.items():
            field = f"{section}.{key}"
            if key not in ALLOWED[section]:
                errs.add(str(field)[:80], "This setting cannot be edited here")
                continue
            if field == "azureDevOps.targets":
                targets = _targets(value, field, errs)
                if targets is not None:
                    out[key] = targets
            elif field == "github.repos":
                repos = _string_list(value, field, errs, gh.MAX_REPOS, "repositories",
                                     gh._validate_repo, "Use owner/repo, for example my-org/web-app", fold=True)
                if repos is not None:
                    out[key] = repos
            elif field == "kubernetes.contexts":
                ctx = _string_list(value, field, errs, k8s.MAX_CONTEXTS, "contexts",
                                   lambda s: bool(CONTEXT_RE.match(s)),
                                   "Use the name shown by kubectl config get-contexts")
                if ctx is not None:
                    out[key] = ctx
            elif field in ("kubernetes.allContexts", "development.mockData"):
                if isinstance(value, bool):
                    out[key] = value
                else:
                    errs.add(field, "Must be true or false")
            else:  # kubernetes.namespaces / excludeNamespaces
                ns = _string_list(value, field, errs, k8s.MAX_NS_FILTERS, "namespaces",
                                  lambda s: len(s) <= 63 and bool(k8s.NS_RE.match(s)),
                                  "Lowercase letters, digits and '-' (a Kubernetes namespace)")
                if ns is not None:
                    out[key] = ns
        if out:
            clean[section] = out
    return clean, errs.items


def _targets(value: Any, field: str, errs: _Errors) -> list[dict] | None:
    if not isinstance(value, list):
        errs.add(field, "Must be a list")
        return None
    if len(value) > az.MAX_TARGETS:
        errs.add(field, f"At most {az.MAX_TARGETS} targets")
        return None
    out: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for i, raw in enumerate(value):
        base = f"{field}.{i}"
        if not isinstance(raw, dict) or set(raw) - {"organization", "project"}:
            errs.add(base, "Each target needs an organization and a project")
            continue
        org, project = _text(raw.get("organization")), _text(raw.get("project"))
        ok = True
        if not org:
            errs.add(base + ".organization", "Required")
            ok = False
        elif not az._validate_org(org):
            errs.add(base + ".organization", "Use https://dev.azure.com/<organization>")
            ok = False
        if not project:
            errs.add(base + ".project", "Required")
            ok = False
        elif not az._validate_project(project):
            errs.add(base + ".project", "Letters, digits, spaces, '-', '.' and '_' (max 64)")
            ok = False
        if not ok:
            continue
        key = (org.rstrip("/").lower(), project.lower())
        if key in seen:
            errs.add(base, "Listed twice")
            continue
        seen.add(key)
        out.append({"organization": org, "project": project})
    return out


# ── Building the new file ─────────────────────────────────────────────────────

def _parse(raw: bytes) -> dict:
    try:
        cfg = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ConfigError("config.json contains invalid JSON -- not modified")
    if not isinstance(cfg, dict):
        raise ConfigError("config.json root is not an object -- not modified")
    return cfg


def _canonical(cfg: dict) -> str:
    return json.dumps(cfg, indent=2, ensure_ascii=False) + "\n"


def build(cfg: dict, clean: dict) -> dict:
    """A copy of CFG with the clean changes applied. Defaults that were never set stay unset."""
    new = copy.deepcopy(cfg)
    for section, body in clean.items():
        block = new.get(section)
        if block is not None and not isinstance(block, dict):
            raise ConfigError(f"config.json '{section}' is not an object -- not modified")
        for key, value in body.items():
            if (block is None or key not in block) and value in ([], False):
                continue            # nothing to say: do not add a key just to hold its default
            if block is None:
                block = new[section] = {}
            block[key] = value
    return new


def _clean_line(line: str) -> str:
    return _CONTROL.sub(" ", line)[:200]


def _diff(old_text: str, new_text: str) -> tuple[list[dict], bool]:
    lines: list[dict] = []
    truncated = False
    first = True
    for line in difflib.unified_diff(old_text.splitlines(), new_text.splitlines(), n=2, lineterm=""):
        if line.startswith(("---", "+++")):
            continue
        if line.startswith("@@"):
            if not first:
                lines.append({"t": " ", "s": "..."})
            first = False
            continue
        if len(lines) >= MAX_DIFF_LINES:
            truncated = True
            break
        lines.append({"t": line[0] if line[:1] in "+-" else " ", "s": _clean_line(line[1:])})
    return lines, truncated


# ── Commands ──────────────────────────────────────────────────────────────────

def _load_changes(arg: str) -> tuple[dict, list[dict]]:
    if len(arg.encode("utf-8", errors="replace")) > MAX_ARG_BYTES:
        raise ConfigError("The changes are too large")
    try:
        parsed = json.loads(arg)
    except ValueError:
        raise ConfigError("The changes are not valid JSON")
    return validate(parsed)


def preview(arg: str) -> int:
    clean, errors = _load_changes(arg)
    if errors:
        return emit({"ok": False, "errors": errors})
    raw = config_store.read_bytes()
    cur = _parse(raw)
    new = build(cur, clean)
    old_text, new_text = _canonical(cur), _canonical(new)
    changed = new != cur
    diff, truncated = _diff(old_text, new_text) if changed else ([], False)
    return emit({"ok": True, "changed": changed,
                 "reformat": raw.decode("utf-8", errors="replace") != old_text,
                 "truncated": truncated, "diff": diff})


def apply(arg: str) -> int:
    clean, errors = _load_changes(arg)
    if errors:
        return emit({"ok": False, "errors": errors})

    def transform(raw: bytes):
        cur = _parse(raw)
        new = build(cur, clean)
        # Nothing to change: write nothing (no new .bak, no reload), even if the
        # file is formatted by hand.
        return None if new == cur else _canonical(new).encode("utf-8")

    wrote = config_store.update(transform, backup=True)
    return emit({"ok": True, "changed": wrote})


def contexts() -> int:
    if not k8s._find_kubectl():
        return fail("kubectl not found")
    names = [n for n in k8s.list_contexts()[:MAX_CONTEXT_LIST] if CONTEXT_RE.match(n)]
    current, err = k8s.get_current_context()
    return emit({"ok": True, "contexts": names, "current": current if (not err and CONTEXT_RE.match(current)) else ""})


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 3 and argv[1] == "preview":
            return preview(argv[2])
        if len(argv) == 3 and argv[1] == "apply":
            return apply(argv[2])
        if len(argv) == 2 and argv[1] == "contexts":
            return contexts()
        return fail("usage: config_edit.py preview|apply '<changes JSON>' | contexts")
    except ConfigError as exc:
        return fail(str(exc))
    except Exception:
        return fail("Unexpected error while changing the settings")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
