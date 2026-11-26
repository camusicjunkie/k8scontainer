# shellcheck shell=bash
# The user-owned tools area (~/.local on the volume): on PATH in every
# interactive shell, login or not, as soon as the admin creates ~/.local/bin.
if [[ $(id -u) -ne 0 && -d $HOME/.local/bin && :$PATH: != *":$HOME/.local/bin:"* ]]; then
    PATH=$HOME/.local/bin:$PATH
fi
