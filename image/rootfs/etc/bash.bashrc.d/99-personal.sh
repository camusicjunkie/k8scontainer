# shellcheck shell=bash
# Personal Config's bashrc, mounted read-only from ~/.devc/personal. Last, so it
# can override anything the image sets.
if [[ -r /etc/devcontainer/personal/bashrc ]]; then
    # shellcheck source=/dev/null
    source /etc/devcontainer/personal/bashrc
fi
