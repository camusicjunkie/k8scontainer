# shellcheck shell=bash
# bash-completion, which also loads every tool's completion from
# /etc/bash_completion.d (the brew-built CLIs put theirs there).
if ! shopt -oq posix && [[ -r /usr/share/bash-completion/bash_completion ]]; then
    # shellcheck source=/dev/null
    source /usr/share/bash-completion/bash_completion
fi
