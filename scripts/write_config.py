#!/usr/bin/python3
"""
scripts/write_config.py
Safely toggle one boolean in this plugin's own config.json: a provider flag
(providers.<name>) or the master switch of the desktop alerts
(notifications.enabled).

Usage:  write_config.py <azureDevOps|kubernetes|github|notifications> <true|false>

Only the allow-listed names and the two literals true/false are accepted;
nothing else can be written. "notifications" means notifications.enabled.

The file lives in the person's config folder (see config_store.py): it is read
with the same limits as read_config.py, is NEVER written through a symlink, and
is replaced atomically (temporary file + rename) under a lock. The new content
is first built in memory, re-parsed and compared with the expected object.

The edit is surgical (only the boolean literal changes, so formatting, key order
and blank lines are kept). If that is not possible (e.g. the key is missing),
the file is rewritten with json.dumps(indent=2).

Exit 0 on success. On failure nothing is changed, a short plain-text
reason goes to stderr, and the exit status is non-zero.
"""
from __future__ import annotations
import copy, json, re, sys

import config_store
from config_store import ConfigError as WriteError

ALLOWED_PROVIDERS = ("azureDevOps", "kubernetes", "github")
NOTIFICATIONS = "notifications"          # argument that selects notifications.enabled


def _target(name: str) -> tuple[str, str]:
    """Map an allow-listed argument to (section, key) inside config.json."""
    if name in ALLOWED_PROVIDERS:
        return "providers", name
    if name == NOTIFICATIONS:
        return "notifications", "enabled"
    raise WriteError("unknown provider")


def _build_new_text(text: str, cfg: dict, section: str, name: str, value: bool) -> str:
    expected = copy.deepcopy(cfg)
    expected[section][name] = value

    literal = "true" if value else "false"
    pattern = re.compile(
        r'("' + re.escape(section) + r'"\s*:\s*\{[^{}]*?"' + re.escape(name) + r'"\s*:\s*)(true|false)'
    )
    matches = list(pattern.finditer(text))
    if len(matches) == 1:
        m = matches[0]
        candidate = text[:m.start(2)] + literal + text[m.end(2):]
        try:
            if json.loads(candidate) == expected:
                return candidate
        except ValueError:
            pass
    # Key not present yet (e.g. a provider added in a later version): append
    # it to the existing, non-empty providers object, keeping the file's own
    # indentation. Only accepted if the result parses to exactly `expected`.
    if not matches:
        block = list(re.finditer(r'("' + re.escape(section) + r'"\s*:\s*\{)([^{}]*?)(\s*)\}', text))
        if len(block) == 1 and block[0].group(2).strip():
            m = block[0]
            body = m.group(2)
            last_line = body.rsplit("\n", 1)[-1]
            indent = last_line[: len(last_line) - len(last_line.lstrip())]
            sep = ("\n" + indent) if "\n" in body else " "
            candidate = (text[:m.end(2)] + "," + sep
                         + json.dumps(name) + ": " + literal + text[m.end(2):])
            try:
                if json.loads(candidate) == expected:
                    return candidate
            except ValueError:
                pass
    # Fallback: full re-serialisation (reformats the file).
    out = json.dumps(expected, indent=2, ensure_ascii=False) + "\n"
    if json.loads(out) != expected:  # paranoia
        raise WriteError("internal consistency check failed")
    return out


def apply(name: str, value: bool) -> None:
    section, key = _target(name)

    def transform(raw: bytes):
        try:
            text = raw.decode("utf-8")
            cfg = json.loads(text)
        except (UnicodeDecodeError, ValueError):
            raise WriteError("config.json contains invalid JSON -- not modified")
        if not isinstance(cfg, dict):
            raise WriteError("config.json root is not an object -- not modified")
        block = cfg.get(section)
        if block is None:
            cfg[section] = {}
        elif not isinstance(block, dict):
            raise WriteError(f"config.json '{section}' is not an object -- not modified")
        new_text = _build_new_text(text, cfg, section, key, value)
        return None if new_text == text else new_text.encode("utf-8")

    config_store.update(transform)


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[2] not in ("true", "false"):
        sys.stderr.write("usage: write_config.py <provider|notifications> <true|false>")
        return 2
    try:
        apply(argv[1], argv[2] == "true")
    except WriteError as e:
        sys.stderr.write(str(e))
        return 1
    except Exception:
        sys.stderr.write("unexpected error writing config.json")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
