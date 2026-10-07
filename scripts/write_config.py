#!/usr/bin/python3
"""
scripts/write_config.py
Safely toggle one provider flag (providers.<name>) in this plugin's own
config.json.

Usage:  write_config.py <azureDevOps|kubernetes|github> <true|false>

Only the allow-listed provider names and the two literals true/false
are accepted; nothing else can be written. The file is read with the same
limits as read_config.py (regular file only, 256 KB cap, no FIFO/device
following) and is NEVER written through a symlink. The new content is
first built in memory, re-parsed, and compared with the expected object;
only then is it written to a temporary file in the same directory and
atomically moved over config.json (os.replace), preserving file mode.

The edit is surgical (only the boolean literal changes, so comments-free
formatting, key order and blank lines are kept). If that is not possible
(e.g. the key is missing), the file is rewritten with json.dumps(indent=2).

Exit 0 on success. On failure nothing is changed, a short plain-text
reason goes to stderr, and the exit status is non-zero.
"""
from __future__ import annotations
import copy, json, os, re, stat, sys, tempfile
from pathlib import Path

MAX_CONFIG_BYTES = 256 * 1024  # 256 KB, same as read_config.py
ALLOWED_PROVIDERS = ("azureDevOps", "kubernetes", "github")

CONFIG_PATH = Path(__file__).parent.parent / "config.json"


class WriteError(Exception):
    pass


def _read_regular(path: Path) -> tuple[bytes, int]:
    """Return (data, mode). Refuses symlinks, non-regular and oversize files."""
    try:
        lst = os.lstat(str(path))
    except FileNotFoundError:
        raise WriteError("config.json not found")
    except OSError as e:
        raise WriteError(f"config.json could not be inspected ({e.strerror or 'error'})")
    if stat.S_ISLNK(lst.st_mode):
        raise WriteError("config.json is a symlink -- edit it manually "
                         "(refusing to write through a symlink)")
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
    except OSError as e:
        raise WriteError(f"config.json could not be opened ({e.strerror or 'error'})")
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise WriteError("config.json is not a regular file")
        if st.st_size > MAX_CONFIG_BYTES:
            raise WriteError(f"config.json is too large ({st.st_size} bytes)")
        data = bytearray()
        while True:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > MAX_CONFIG_BYTES:
                raise WriteError("config.json exceeded the size limit while reading")
        return bytes(data), stat.S_IMODE(st.st_mode)
    except OSError as e:
        raise WriteError(f"error reading config.json ({e.strerror or 'error'})")
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def _build_new_text(text: str, cfg: dict, name: str, value: bool) -> str:
    expected = copy.deepcopy(cfg)
    expected["providers"][name] = value

    literal = "true" if value else "false"
    pattern = re.compile(
        r'("providers"\s*:\s*\{[^{}]*?"' + re.escape(name) + r'"\s*:\s*)(true|false)'
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
        block = list(re.finditer(r'("providers"\s*:\s*\{)([^{}]*?)(\s*)\}', text))
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


def _atomic_write(path: Path, text: str, mode: int) -> None:
    data = text.encode("utf-8")
    if len(data) > MAX_CONFIG_BYTES:
        raise WriteError("resulting config.json would be too large")
    fd, tmp = tempfile.mkstemp(prefix=".config.json.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, str(path))
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise WriteError(f"could not write config.json ({e.strerror or 'error'})")
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def apply(path: Path, name: str, value: bool) -> None:
    if name not in ALLOWED_PROVIDERS:
        raise WriteError("unknown provider")
    raw, mode = _read_regular(path)
    try:
        text = raw.decode("utf-8")
        cfg = json.loads(text)
    except (UnicodeDecodeError, ValueError):
        raise WriteError("config.json contains invalid JSON -- not modified")
    if not isinstance(cfg, dict):
        raise WriteError("config.json root is not an object -- not modified")
    providers = cfg.get("providers")
    if providers is None:
        cfg["providers"] = {}
    elif not isinstance(providers, dict):
        raise WriteError("config.json 'providers' is not an object -- not modified")
    new_text = _build_new_text(text, cfg, name, value)
    if new_text == text:
        return  # nothing to do
    _atomic_write(path, new_text, mode)


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[2] not in ("true", "false"):
        sys.stderr.write("usage: write_config.py <provider> <true|false>")
        return 2
    try:
        apply(CONFIG_PATH, argv[1], argv[2] == "true")
    except WriteError as e:
        sys.stderr.write(str(e))
        return 1
    except Exception:
        sys.stderr.write("unexpected error writing config.json")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
