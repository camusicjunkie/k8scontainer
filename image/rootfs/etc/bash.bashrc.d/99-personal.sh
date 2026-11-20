# shellcheck shell=bash
# Personal Config's bashrc, on the admin's volume at ~/.devc/personal. Last, so it
# can override anything the image sets.
if [[ -r "$HOME/.devc/personal/bashrc" ]]; then
    # shellcheck source=/dev/null
    source "$HOME/.devc/personal/bashrc"
fi
