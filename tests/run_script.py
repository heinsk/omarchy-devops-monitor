#!/usr/bin/env python3
"""
Runs one provider script with its CLI replaced by a test double, so the tests
never depend on (or touch) the real az / kubectl / gh of the machine.

    run_script.py SCRIPT [--kubectl PATH] [--az PATH] [--gh PATH] [--no-tools] -- ARGS...

SCRIPT is azure_devops, kubernetes or github_actions. The scripts cache the
location of their CLI in a module-level variable; this runner fills it in
before calling main(). --no-tools makes every lookup of a CLI fail, which is
how the "not installed" case is tested on a machine that has the tool.
"""
import importlib.util
import shutil
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


def main() -> int:
    argv = sys.argv[1:]
    script = argv.pop(0)
    sep = argv.index("--") if "--" in argv else len(argv)
    own, rest = argv[:sep], argv[sep + 1:]
    sys.path.insert(0, str(SCRIPTS))
    spec = importlib.util.spec_from_file_location("provider_under_test", SCRIPTS / (script + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    i = 0
    while i < len(own):
        flag = own[i]
        if flag == "--no-tools":
            shutil.which = lambda *a, **k: None
            if hasattr(mod, "_discover_home_gh"):
                mod._discover_home_gh = lambda: None
            i += 1
            continue
        var = {"--kubectl": "_KUBECTL_PATH", "--az": "_AZ_PATH", "--gh": "_GH_PATH"}[flag]
        setattr(mod, var, own[i + 1])
        i += 2
    sys.argv = [script + ".py"] + rest
    return mod.main()


if __name__ == "__main__":
    sys.exit(main())
