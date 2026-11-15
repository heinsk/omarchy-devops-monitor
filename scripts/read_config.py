#!/usr/bin/python3
"""
scripts/read_config.py
Safely read this plugin's own config.json.

    read_config.py            print the config file (see config_store.py for where it
                              lives, the one-time migration and the safety rules)
    read_config.py --path     print the absolute path of the config file (creates nothing)

Outputs the raw bytes to stdout on success (exit 0). On failure it writes nothing
to stdout, writes a short plain-text reason to stderr and exits non-zero, so the
caller can both fall back to an empty config AND show the person why.
"""
from __future__ import annotations
import sys

import config_store


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] == "--path":
        sys.stdout.write(config_store.config_path())
        return 0
    if len(argv) != 1:
        sys.stderr.write("usage: read_config.py [--path]")
        return 2
    try:
        data = config_store.read_bytes()
    except config_store.ConfigError as exc:
        sys.stderr.write(str(exc))
        return 1
    except Exception:
        sys.stderr.write("config.json could not be read")
        return 1
    sys.stdout.buffer.write(data)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
