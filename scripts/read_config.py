#!/usr/bin/python3
"""
scripts/read_config.py
Safely read this plugin's own config.json.

Reads at most MAX_CONFIG_BYTES from a regular file only -- refuses to
follow through to special files (FIFOs, character/block devices) even
if config.json has been replaced by a symlink to one, and refuses files
larger than the cap. Outputs raw bytes to stdout on success (exit 0);
on failure, writes nothing to stdout, writes a short plain-text reason
to stderr, and exits non-zero, so the caller can both fall back to an
empty config AND show the person why.
"""
from __future__ import annotations
import os, stat, sys
from pathlib import Path

MAX_CONFIG_BYTES = 256 * 1024  # 256 KB

CONFIG_PATH = Path(__file__).parent.parent / "config.json"


def _fail(reason: str) -> None:
    sys.stderr.write(reason)


def read_config_safely(path: Path, max_bytes: int) -> bytes | None:
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NONBLOCK)
    except FileNotFoundError:
        _fail("config.json not found")
        return None
    except PermissionError:
        _fail("config.json is not readable (permission denied)")
        return None
    except OSError as e:
        _fail(f"config.json could not be opened ({e.strerror or 'error'})")
        return None

    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            _fail("config.json is not a regular file (symlink to a "
                  "device/pipe/socket was rejected)")
            return None
        if st.st_size > max_bytes:
            _fail(f"config.json is too large ({st.st_size} bytes, "
                  f"limit is {max_bytes})")
            return None

        data = bytearray()
        while True:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > max_bytes:
                _fail(f"config.json exceeded the {max_bytes}-byte limit "
                      f"while reading")
                return None
        return bytes(data)
    except OSError as e:
        _fail(f"error reading config.json ({e.strerror or 'error'})")
        return None
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def main() -> int:
    data = read_config_safely(CONFIG_PATH, MAX_CONFIG_BYTES)
    if data is None:
        return 1
    sys.stdout.buffer.write(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
