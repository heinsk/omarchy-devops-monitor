#!/usr/bin/python3
"""
scripts/config_store.py
Where the plugin's config.json lives, and the only code that reads or writes it.

Location:  $XDG_CONFIG_HOME/io.github.heinsk.devops-monitor/config.json
           (default ~/.config/io.github.heinsk.devops-monitor/config.json;
           only an absolute $XDG_CONFIG_HOME is honoured)

Why not the plugin folder: Omarchy reloads a plugin whenever a file inside its
folder changes, so every save from the panel would reload the plugin. A file in
the person's own config folder does not have that effect.

Migration (once, automatic): when the file above does not exist yet, it is
created from the config.json that used to live in the plugin folder (copied
byte for byte; the old file is never changed or deleted). If there is no old
file, a minimal default with every provider off is created. After that the old
file is ignored. A damaged old file is NOT copied: the reason is reported and
nothing is created.

Safety rules (this file holds the person's settings, so it is strict):
  - the folder is created 0700 and must belong to the current user; it is opened
    with O_NOFOLLOW (a link in its place is refused) and every later access goes
    through that descriptor;
  - the file is created 0600; it is NEVER written through a symlink and only
    regular files are read (a FIFO or device is refused);
  - reads and writes are capped at MAX_CONFIG_BYTES;
  - writes are atomic (temporary file + rename in the same folder) and serialized
    with flock, so two writers can never leave a half file;
  - a copy of the previous content can be kept as config.json.bak.
No credentials are ever stored here.
"""
from __future__ import annotations

import fcntl
import json
import os
import secrets
import stat
from pathlib import Path
from typing import Callable

PLUGIN_ID        = "io.github.heinsk.devops-monitor"
FILE_NAME        = "config.json"
BACKUP_NAME      = "config.json.bak"
MAX_CONFIG_BYTES = 256 * 1024  # 256 KB

# The config.json that shipped inside the plugin folder (the old location).
LEGACY_PATH = Path(__file__).parent.parent / "config.json"

# Used only when there is no old file to copy.
DEFAULT_CONFIG = {"providers": {"azureDevOps": False, "kubernetes": False, "github": False}}


class ConfigError(Exception):
    """A short, plain-text reason that is safe to show to the person."""


# ── Location ──────────────────────────────────────────────────────────────────

def config_dir_path() -> str:
    base = os.environ.get("XDG_CONFIG_HOME", "")
    if not base or not os.path.isabs(base):
        base = os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, PLUGIN_ID)


def config_path() -> str:
    return os.path.join(config_dir_path(), FILE_NAME)


def _open_dir(create: bool) -> int:
    """Open the config folder with O_NOFOLLOW and check owner / type. Returns an fd."""
    path = config_dir_path()
    if create:
        try:
            os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
        except OSError as exc:
            raise ConfigError(f"the config folder could not be created ({exc.strerror or 'error'})")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as exc:
        raise ConfigError(f"the config folder is not available ({exc.strerror or 'error'})")
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        os.close(fd)
        raise ConfigError("the config folder is not owned by the current user")
    if st.st_mode & 0o077:
        try:
            os.fchmod(fd, 0o700)          # ours, but too open: tighten it
        except OSError:
            pass
    return fd


# ── Reading ───────────────────────────────────────────────────────────────────

def _read_fd(fd: int, label: str) -> bytes:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        raise ConfigError(f"{label} is not a regular file")
    if st.st_size > MAX_CONFIG_BYTES:
        raise ConfigError(f"{label} is too large ({st.st_size} bytes, limit is {MAX_CONFIG_BYTES})")
    data = bytearray()
    while True:
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        data.extend(chunk)
        if len(data) > MAX_CONFIG_BYTES:
            raise ConfigError(f"{label} exceeded the {MAX_CONFIG_BYTES}-byte limit while reading")
    return bytes(data)


def _read_in_dir(dfd: int) -> bytes:
    try:
        fd = os.open(FILE_NAME, os.O_RDONLY | os.O_NONBLOCK, dir_fd=dfd)
    except FileNotFoundError:
        raise ConfigError("config.json not found")
    except PermissionError:
        raise ConfigError("config.json is not readable (permission denied)")
    except OSError as exc:
        raise ConfigError(f"config.json could not be opened ({exc.strerror or 'error'})")
    try:
        return _read_fd(fd, "config.json")
    except OSError as exc:
        raise ConfigError(f"error reading config.json ({exc.strerror or 'error'})")
    finally:
        os.close(fd)


def _read_legacy() -> bytes | None:
    """The old config.json in the plugin folder. None when there is none."""
    try:
        fd = os.open(str(LEGACY_PATH), os.O_RDONLY | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise ConfigError(f"the config.json in the plugin folder could not be opened ({exc.strerror or 'error'})")
    try:
        data = _read_fd(fd, "the config.json in the plugin folder")
    except OSError as exc:
        raise ConfigError(f"error reading the config.json in the plugin folder ({exc.strerror or 'error'})")
    finally:
        os.close(fd)
    try:
        ok = isinstance(json.loads(data.decode("utf-8")), dict)
    except (UnicodeDecodeError, ValueError):
        ok = False
    if not ok:
        raise ConfigError("the config.json in the plugin folder is not valid JSON, so it was not copied")
    return data


# ── Writing ───────────────────────────────────────────────────────────────────

def _write_tmp(dfd: int, data: bytes, mode: int) -> str:
    """Write DATA to a new private temporary file in the folder. Returns its name."""
    if len(data) > MAX_CONFIG_BYTES:
        raise ConfigError("the resulting config.json would be too large")
    for _ in range(8):
        name = ".config." + secrets.token_hex(6) + ".tmp"
        try:
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
        except FileExistsError:
            continue
        except OSError as exc:
            raise ConfigError(f"could not write config.json ({exc.strerror or 'error'})")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(name, mode, dir_fd=dfd)
        except OSError as exc:
            _unlink(dfd, name)
            raise ConfigError(f"could not write config.json ({exc.strerror or 'error'})")
        except BaseException:
            _unlink(dfd, name)
            raise
        return name
    raise ConfigError("could not write config.json (no free temporary name)")


def _unlink(dfd: int, name: str) -> None:
    try:
        os.unlink(name, dir_fd=dfd)
    except OSError:
        pass


def _create_if_missing(dfd: int, data: bytes) -> bool:
    """Create config.json from DATA unless it exists already. True when created here."""
    tmp = _write_tmp(dfd, data, 0o600)
    try:
        os.link(tmp, FILE_NAME, src_dir_fd=dfd, dst_dir_fd=dfd, follow_symlinks=False)
        return True
    except FileExistsError:
        return False                    # somebody else created it first: keep theirs
    except OSError as exc:
        raise ConfigError(f"could not create config.json ({exc.strerror or 'error'})")
    finally:
        _unlink(dfd, tmp)


def _exists(dfd: int) -> bool:
    try:
        os.lstat(FILE_NAME, dir_fd=dfd)
        return True
    except FileNotFoundError:
        return False
    except OSError:
        return True                     # let the read report the real problem


# ── Public API ────────────────────────────────────────────────────────────────

def ensure_config() -> bool:
    """Make sure the config file exists (the one-time migration). True if it was created now."""
    dfd = _open_dir(create=True)
    try:
        fcntl.flock(dfd, fcntl.LOCK_EX)
        if _exists(dfd):
            return False
        data = _read_legacy()
        if data is None:
            data = (json.dumps(DEFAULT_CONFIG, indent=2) + "\n").encode("utf-8")
        return _create_if_missing(dfd, data)
    finally:
        os.close(dfd)                   # also releases the lock


def read_bytes() -> bytes:
    """The config file's bytes (creating it first if this is the first run)."""
    ensure_config()
    dfd = _open_dir(create=False)
    try:
        return _read_in_dir(dfd)
    finally:
        os.close(dfd)


def update(transform: Callable[[bytes], bytes | None], backup: bool = False) -> bool:
    """Read-modify-write under a lock.

    TRANSFORM gets the current bytes and returns the new bytes, or None for "no
    change". Refuses to write through a symlink. With BACKUP, the previous
    content is first saved as config.json.bak. Returns True when it wrote.
    """
    ensure_config()
    dfd = _open_dir(create=False)
    try:
        fcntl.flock(dfd, fcntl.LOCK_EX)
        try:
            lst = os.lstat(FILE_NAME, dir_fd=dfd)
        except FileNotFoundError:
            raise ConfigError("config.json not found")
        if stat.S_ISLNK(lst.st_mode):
            raise ConfigError("config.json is a symlink -- edit it manually "
                              "(refusing to write through a symlink)")
        if not stat.S_ISREG(lst.st_mode):
            raise ConfigError("config.json is not a regular file")
        old = _read_in_dir(dfd)
        new = transform(old)
        if new is None or new == old:
            return False
        mode = stat.S_IMODE(lst.st_mode) or 0o600
        if backup:
            bak = _write_tmp(dfd, old, 0o600)
            try:
                os.rename(bak, BACKUP_NAME, src_dir_fd=dfd, dst_dir_fd=dfd)
            except OSError as exc:
                _unlink(dfd, bak)
                raise ConfigError(f"could not save config.json.bak ({exc.strerror or 'error'})")
        tmp = _write_tmp(dfd, new, mode)
        try:
            os.rename(tmp, FILE_NAME, src_dir_fd=dfd, dst_dir_fd=dfd)
        except OSError as exc:
            _unlink(dfd, tmp)
            raise ConfigError(f"could not write config.json ({exc.strerror or 'error'})")
        return True
    finally:
        os.close(dfd)
