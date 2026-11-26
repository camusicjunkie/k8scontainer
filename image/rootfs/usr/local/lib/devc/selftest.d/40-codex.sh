# shellcheck shell=bash
# Codex: the static binary runs offline, and the wrapper is what's on PATH.

check "codex --version (static binary, offline)" /usr/local/lib/codex/codex --version
check "codex on PATH is the gateway wrapper" test "$(command -v codex)" = /usr/local/bin/codex
check "Codex's system config is in place" test -r /etc/codex/config.toml
