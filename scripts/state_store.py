#!/usr/bin/python3
"""
scripts/state_store.py
The plugin's only piece of persistent state: which providers have their
notifications silenced. (Everything else lives in config.json, which this
script never touches.)

Usage:
    state_store.py read
    state_store.py mute <azureDevOps|kubernetes|github> <EPOCH_SECONDS|forever|clear>

`read` prints {"mute": {"<provider>": <epoch seconds> | -1 (forever)}} and
ALWAYS succeeds: a missing, unreadable, oversized, foreign or corrupt file is
treated as "nothing silenced".

Where: $XDG_STATE_HOME/io.github.heinsk.devops-monitor/state.json (default
~/.local/state/...). Only an absolute $XDG_STATE_HOME is honoured.

Safety rules (this is a file the plugin writes on its own, so it is strict):
  - the folder is created 0700 and the file 0600; both must belong to the
    current user, and neither may be a symlink (the folder is opened with
    O_NOFOLLOW and every later access goes through that descriptor);
  - writes are atomic (temporary file + rename in the same folder) and
    serialized with flock, so two writers can never leave a half file;
  - the file is capped at 16 KiB and only the allow-listed providers and
    integer values survive a read; anything else is dropped;
  - no credentials, names of pods or any provider data are ever stored.
"""
from __future__ import annotations

import fcntl
import json
import os
import stat
import sys
import time

PLUGIN_ID = "io.github.heinsk.devops-monitor"
PROVIDERS = ("azureDevOps", "kubernetes", "github")
MAX_BYTES = 16 * 1024
FILE_NAME = "state.json"
LOCK_NAME = "state.lock"
MAX_EPOCH = 2 ** 40          # ~ year 36000; anything above is rejected


class StateError(Exception):
    pass


def _state_dir_path() -> str:
    base = os.environ.get("XDG_STATE_HOME", "")
    if not base or not os.path.isabs(base):
        base = os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, PLUGIN_ID)


def _open_dir(create: bool) -> int:
    """Open the state folder with O_NOFOLLOW and check owner / type. Returns an fd."""
    path = _state_dir_path()
    if create:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as exc:
        raise StateError(f"state folder not available ({exc.strerror or 'error'})")
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        os.close(fd)
        raise StateError("state folder is not owned by the current user")
    if st.st_mode & 0o077:
        os.fchmod(fd, 0o700)          # ours, but too open: tighten it
    return fd


def _clean(obj: object, now: float) -> dict[str, int]:
    """Keep only allow-listed providers with an integer value; drop expired ones."""
    mute: dict[str, int] = {}
    raw = obj.get("mute") if isinstance(obj, dict) else None
    if isinstance(raw, dict):
        for name in PROVIDERS:
            value = raw.get(name)
            if isinstance(value, bool) or not isinstance(value, int):
                continue
            if value == -1 or (0 < value <= MAX_EPOCH and value > now):
                mute[name] = value
    return mute


def _read_file(dfd: int) -> dict:
    try:
        fd = os.open(FILE_NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    except OSError:
        return {}
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size > MAX_BYTES:
            return {}
        data = os.read(fd, MAX_BYTES + 1)
    finally:
        os.close(fd)
    if len(data) > MAX_BYTES:
        return {}
    try:
        return json.loads(data.decode("utf-8"))
    except Exception:
        return {}


def read_state() -> dict[str, dict[str, int]]:
    try:
        dfd = _open_dir(create=False)
    except StateError:
        return {"mute": {}}
    try:
        return {"mute": _clean(_read_file(dfd), time.time())}
    finally:
        os.close(dfd)


def write_mute(provider: str, until: str) -> None:
    if provider not in PROVIDERS:
        raise StateError("unknown provider")
    if until == "forever":
        value: int | None = -1
    elif until == "clear":
        value = None
    else:
        try:
            value = int(until)
        except ValueError:
            raise StateError("invalid time")
        if not 0 < value <= MAX_EPOCH:
            raise StateError("invalid time")
    dfd = _open_dir(create=True)
    try:
        lock = os.open(LOCK_NAME, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX)
            mute = _clean(_read_file(dfd), time.time())
            if value is None:
                mute.pop(provider, None)
            else:
                mute[provider] = value
            payload = json.dumps({"version": 1, "mute": mute}, separators=(",", ":")).encode()
            tmp = f".{FILE_NAME}.{os.getpid()}.tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
            try:
                try:
                    os.write(fd, payload)
                    os.fsync(fd)
                finally:
                    os.close(fd)
                os.rename(tmp, FILE_NAME, src_dir_fd=dfd, dst_dir_fd=dfd)
            except BaseException:
                try:
                    os.unlink(tmp, dir_fd=dfd)       # never leave a half-written temporary file
                except OSError:
                    pass
                raise
        finally:
            os.close(lock)           # releases the flock
    finally:
        os.close(dfd)


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] == "read":
        print(json.dumps(read_state()))
        return 0
    if len(argv) == 4 and argv[1] == "mute":
        try:
            write_mute(argv[2], argv[3])
        except (StateError, OSError) as exc:
            sys.stderr.write("state not saved: %s\n" % (getattr(exc, "strerror", None) or exc))
            return 1
        return 0
    sys.stderr.write("usage: state_store.py read | mute <provider> <epoch|forever|clear>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
