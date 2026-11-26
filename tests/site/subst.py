#!/usr/bin/env python3
"""Substitutes the runtime facts into YAML on stdin, as Flux's postBuild does
with StrictPostBuildSubstitutions: ${NAME} and ${NAME:=default}, and a variable
with no value and no default fails.

    python3 tests/site/subst.py <in.yaml >out.yaml   # substitute
    python3 tests/site/subst.py --names              # the contract's names

Values come from facts.env beside this file; set NAME in the environment to
override one. DEVCONTAINER_SITE_ENV_B64 and DEVCONTAINER_SITE_CA_B64 are
computed from site.env and site-ca.crt unless overridden.
"""
import base64
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::=([^}]*))?\}")


def facts():
    out = {}
    for line in (HERE / "facts.env").read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    out["DEVCONTAINER_SITE_ENV_B64"] = base64.b64encode((HERE / "site.env").read_bytes()).decode()
    out["DEVCONTAINER_SITE_CA_B64"] = base64.b64encode((HERE / "site-ca.crt").read_bytes()).decode()
    for k in out:
        if k in os.environ:
            out[k] = os.environ[k]
    return out


def main():
    values = facts()
    if sys.argv[1:] == ["--names"]:
        print("\n".join(values))
        return
    missing = []

    def sub(m):
        name, default = m.group(1), m.group(2)
        if name in values and values[name] != "":
            return values[name]
        if default is not None:
            return default
        if name in values:
            return ""
        missing.append(name)
        return m.group(0)

    text = VAR.sub(sub, sys.stdin.read())
    if missing:
        sys.exit("subst.py: no value for " + ", ".join(sorted(set(missing))) + " (not in tests/site/facts.env)")
    sys.stdout.write(text)


main()
