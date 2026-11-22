# shellcheck shell=bash
# The VS Code server and extensions: baked in at the commit pinned in vscode.env,
# owned by the container user, and usable offline with no root.

vscode_pins=${DEVC_VSCODE_PINS:-/usr/local/share/devc/packages/vscode.env}
vscode_extension_pins=${DEVC_VSCODE_EXTENSION_PINS:-/usr/local/share/devc/packages/vscode-extensions.txt}
vscode_home=${DEVC_VSCODE_DIR:-$HOME/.vscode-server}
vscode_commit=$(sed -n 's/^VSCODE_COMMIT=//p' "$vscode_pins" 2>/dev/null)
server=$vscode_home/bin/$vscode_commit/bin/code-server

# Extension ids are case-insensitive; compare lowercased.
lower() { tr '[:upper:]' '[:lower:]'; }

pinned_extensions() {
    grep -vE '^[[:space:]]*(#|$)' "$vscode_extension_pins" | sed 's/@/ /' | lower | LC_ALL=C sort
}

installed_extensions() {
    jq -r '.[] | "\(.identifier.id) \(.version)"' "$vscode_home/extensions/extensions.json" | lower | LC_ALL=C sort
}

server_is_pinned_commit() {
    [[ -n $vscode_commit ]] || { echo "no VSCODE_COMMIT in $vscode_pins"; return 1; }
    [[ $(manifest_value vscode_commit) == "$vscode_commit" ]] \
        || { echo "MANIFEST vscode_commit '$(manifest_value vscode_commit)' is not the pin $vscode_commit"; return 1; }
    local got
    got=$("$server" --version | sed -n 2p) || return 1
    [[ $got == "$vscode_commit" ]] || { echo "server reports commit '$got', pin is $vscode_commit"; return 1; }
}

extensions_match_pins() {
    local want have
    want=$(pinned_extensions)
    [[ -n $want ]] || { echo "no extensions pinned"; return 1; }
    have=$(installed_extensions) || return 1
    # Dependencies pulled in at build time may add extras; every pin must be there.
    local missing
    missing=$(comm -23 <(echo "$want") <(echo "$have"))
    [[ -z $missing ]] || { echo "pinned but not installed:"; echo "$missing"; return 1; }
}

extensions_match_manifest() {
    local want have
    want=$(manifest_section extensions | lower | LC_ALL=C sort)
    have=$(installed_extensions) || return 1
    [[ -n $want && $want == "$have" ]] && return 0
    echo "MANIFEST vs installed:"
    diff <(echo "$want") <(echo "$have")
    return 1
}

extensions_on_disk() {
    local dir ok=0
    while IFS= read -r dir; do
        [[ -d $vscode_home/extensions/$dir ]] || { echo "missing: $dir"; ok=1; }
    done < <(jq -r '.[].relativeLocation' "$vscode_home/extensions/extensions.json")
    return "$ok"
}

server_lists_extensions() {
    local have missing
    have=$("$server" --extensions-dir "$vscode_home/extensions" --list-extensions --show-versions \
        | sed 's/@/ /' | lower | LC_ALL=C sort) || return 1
    missing=$(comm -23 <(pinned_extensions) <(echo "$have"))
    [[ -z $missing ]] || { echo "server does not list:"; echo "$missing"; return 1; }
}

# Remote-SSH starts the server with --start-server; it must come up with no
# network and no root, and say where it listens.
server_starts_offline() {
    local log pid i
    log=$(mktemp) || return 1
    "$server" --start-server --host 127.0.0.1 --port 0 --without-connection-token \
        --accept-server-license-terms --server-data-dir "$(mktemp -d)" \
        --extensions-dir "$vscode_home/extensions" >"$log" 2>&1 </dev/null &
    pid=$!
    for i in $(seq 60); do
        if grep -q 'listening on' "$log"; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    tail -n 15 "$log"
    return 1
}

owned_by_user() {
    local bad
    bad=$(find "$vscode_home" ! -user "$(id -un)" 2>/dev/null | head -n3)
    [[ -z $bad ]] || { echo "not owned by $(id -un):"; echo "$bad"; return 1; }
    [[ -w $vscode_home && -w $vscode_home/extensions ]]
}

# Remote-SSH's exec-server layout: the CLI at code-<commit> runs the same server
# from cli/servers/Stable-<commit>/server, so either layout finds it offline.
exec_server_layout() {
    local cli=$vscode_home/code-$vscode_commit
    local alt=$vscode_home/cli/servers/Stable-$vscode_commit/server
    [[ -x $cli ]] || { echo "no $cli"; return 1; }
    "$cli" --version | grep -q "commit $vscode_commit" || { echo "$cli is not commit $vscode_commit"; return 1; }
    [[ -x $alt/bin/code-server ]] || { echo "no $alt/bin/code-server"; return 1; }
    [[ $("$alt/bin/code-server" --version | sed -n 2p) == "$vscode_commit" ]] || { echo "$alt is not commit $vscode_commit"; return 1; }
}

# The CLI's prerequisite check finds libstdc++ at /usr/lib64/libstdc++.so.6 or
# through `ldconfig -p`; failing both, it refuses to start the server.
cli_finds_libstdcxx() {
    [[ -e /usr/lib64/libstdc++.so.6 ]] && return 0
    /sbin/ldconfig -p | grep -q 'libstdc++\.so\.6 ' || { echo "ldconfig -p lists no libstdc++.so.6"; return 1; }
}

# VS Code terminals set LANG from the Workstation's display language.
terminal_locale() {
    locale -a | grep -qix 'en_US\.utf8' || { echo "en_US.UTF-8 missing; have: $(locale -a | tr '\n' ' ')"; return 1; }
    [[ -z $(LANG=en_US.UTF-8 bash -c : 2>&1) ]] || { echo "bash warns under LANG=en_US.UTF-8"; return 1; }
}

check "the VS Code server is the pinned commit" server_is_pinned_commit
check "the exec-server layout (code-<commit> and cli/servers/Stable-<commit>/server) is staged" exec_server_layout
check "the VS Code CLI finds libstdc++ (its prerequisite check)" cli_finds_libstdcxx
check "VS Code terminals' locale (en_US.UTF-8) exists" terminal_locale
check "the baked extensions include every pinned one" extensions_match_pins
check "the baked extensions match MANIFEST" extensions_match_manifest
check "every extension is on disk" extensions_on_disk
check "the server lists the pinned extensions" server_lists_extensions
check "the VS Code server starts with no network and no root" server_starts_offline
check "the VS Code server tree belongs to the container user" owned_by_user
