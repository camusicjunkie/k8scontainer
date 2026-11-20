# shellcheck shell=bash
# The user-owned tools area (~/.local, on the volume): a tool the admin puts in
# ~/.local/bin is on PATH in new shells, with no root and no network.

user_tool_on_path() {
    local flag=$1 home out
    home=$(mktemp -d) || return 1
    install -d "$home/.local/bin"
    printf '#!/bin/sh\necho user-tool-ran\n' >"$home/.local/bin/devc-user-tool"
    chmod 0755 "$home/.local/bin/devc-user-tool"
    out=$(HOME=$home bash "$flag" -c devc-user-tool 2>&1 </dev/null) || { echo "$out"; return 1; }
    [[ $out == *user-tool-ran ]] || { echo "got '$out'"; return 1; }
}

check "a tool in ~/.local/bin is on PATH in a login shell" user_tool_on_path -l
check "a tool in ~/.local/bin is on PATH in an interactive shell" user_tool_on_path -i
