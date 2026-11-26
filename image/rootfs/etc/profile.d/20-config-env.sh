# shellcheck shell=bash
# Site Config and Personal Config settings (NAME=value lines) in every login
# shell, interactive or not (ssh host command): klogin, its completion and the
# Secrets File helpers read them. Site Config is the read-only ConfigMap Flux
# renders; personal.env lives on the admin's volume and, loaded second,
# overrides it.
set -a
for _devc_env in /etc/devcontainer/site/site.env "$HOME/.devc/personal/personal.env"; do
    # shellcheck source=/dev/null
    [[ -r $_devc_env ]] && . "$_devc_env"
done
set +a
unset _devc_env
