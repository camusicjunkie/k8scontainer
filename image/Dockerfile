# syntax=docker/dockerfile:1
# The Standard Image. `docker build image/` builds it with the pins below as
# defaults; CI overrides DEVC_VERSION and DEVC_GIT_SHA. Nothing in the image
# reaches the network at runtime. It runs as a non-root user and has no sudo.
# Not in this image yet: kubectl-vsphere (it needs a Supervisor's plugin zip).

ARG DHI_BASE=dhi.io/debian-base:trixie-dev@sha256:f90fd43cdf3dd94840b4dc3a2a39fd2a08578e40e7895535e2e20a1275ba6013
ARG BREW_IMAGE=docker.io/homebrew/brew:4.6.20@sha256:b0072bfdebf5934ae24b93b44a1928a88057399b3283ffa0177bb86084fdedfd
ARG HADOLINT_IMAGE=docker.io/hadolint/hadolint:v2.15.1-debian@sha256:9a3944b7fddcb947d1ffd90829ac1a6e5c30479223358f249d8b96c7d0019e27

# ------------------------------------------------------------------ hadolint
# Its static binary. Brew's build needs brew's gmp and libffi, and apt has none.
FROM ${HADOLINT_IMAGE} AS hadolint

# ------------------------------------------------------------------ brew
# brew installs the CLIs from the flat list, latest at build time, and
# only their binaries, completions and versions leave this stage.
FROM ${BREW_IMAGE} AS brew
RUN --mount=type=bind,source=packages/brew.txt,target=/tmp/brew.txt \
    --mount=type=bind,source=build,target=/tmp/build \
    bash /tmp/build/brew-export.sh /tmp/brew.txt /home/linuxbrew/export

# Checked on the DHI base, against the loader and glibc the image will use:
# static binaries pass, glibc-only ones move onto the system loader, and
# anything that needs a brew library fails the build.
FROM ${DHI_BASE} AS brew-check
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends patchelf \
    && rm -rf /var/lib/apt/lists/*
COPY --from=brew /home/linuxbrew/export /tmp/in
RUN --mount=type=bind,source=build,target=/tmp/build \
    bash /tmp/build/brew-check.sh /tmp/in /out

# ------------------------------------------------------------------ downloads
# Pinned upstream binaries, each checked against its SHA-256.
FROM ${DHI_BASE} AS downloads
ARG CODEX_VERSION=0.162.0
ARG CODEX_SHA256=8daf67f6261161aa5939d8d42a516032d760406216779d7ce6040f242140ff73
ARG TFLINT_VERSION=0.64.0
ARG TFLINT_SHA256=cca9d13e2e1d7a2c627af60ff899a3c9b74212899416aeb96ec764d2ef954537
ARG PWSH_VERSION=7.6.6
ARG PWSH_SHA256=ddbc4a2d113bbd46d283cfedcbcd117a70caefd7673f41f2b4e0000badf103bc
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends unzip \
    && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:${CODEX_SHA256} \
    https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-x86_64-unknown-linux-musl.tar.gz \
    /tmp/codex.tar.gz
ADD --checksum=sha256:${TFLINT_SHA256} \
    https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_amd64.zip \
    /tmp/tflint.zip
ADD --checksum=sha256:${PWSH_SHA256} \
    https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz \
    /tmp/pwsh.tar.gz
RUN install -d /out/pwsh \
    && tar -xzf /tmp/pwsh.tar.gz -C /out/pwsh \
    && chmod 0755 /out/pwsh/pwsh \
    && tar -xzf /tmp/codex.tar.gz -C /tmp \
    && install -D -m 0755 /tmp/codex-x86_64-unknown-linux-musl /out/codex/codex \
    && unzip -q -d /tmp/tflint /tmp/tflint.zip \
    && install -D -m 0755 /tmp/tflint/tflint /out/bin/tflint

# ------------------------------------------------------------------ python
# The one venv, built at the path it runs from, from a wheelhouse that ships
# with it so `pip install --no-index` works offline. Then the Ansible
# collections, with that venv's ansible-galaxy.
FROM ${DHI_BASE} AS python
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*
RUN --mount=type=bind,source=packages,target=/mnt/packages \
    python3 -m venv /opt/venv \
    && /opt/venv/bin/pip wheel --quiet -r /mnt/packages/python.txt -w /opt/python-wheels \
    && /opt/venv/bin/pip install --quiet --no-index --find-links /opt/python-wheels -r /mnt/packages/python.txt \
    && /opt/venv/bin/pip freeze | sed 's/==/ /' | LC_ALL=C sort >/python-versions.txt
RUN --mount=type=bind,source=packages,target=/mnt/packages \
    /opt/venv/bin/ansible-galaxy collection install \
        -r /mnt/packages/ansible-collections.yml -p /usr/share/ansible/collections \
    && /opt/venv/bin/ansible-galaxy collection list --format json -p /usr/share/ansible/collections \
        | /opt/venv/bin/python3 -c 'import json, sys; [print(n, c["version"]) for p in json.load(sys.stdin).values() for n, c in sorted(p.items())]' \
        >/collection-versions.txt

# ------------------------------------------------------------------ caches
# Terraform providers, Packer plugins and PowerShell modules, each resolved to
# the newest version inside its major-version constraint.
FROM ${DHI_BASE} AS caches
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libicu76 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=brew-check /out/bin/terraform /out/bin/packer /usr/local/bin/
COPY --from=downloads /out/pwsh /opt/microsoft/powershell/7
ENV CHECKPOINT_DISABLE=1 \
    PACKER_PLUGIN_PATH=/usr/local/share/packer/plugins \
    POWERSHELL_TELEMETRY_OPTOUT=1
RUN --mount=type=bind,source=packages,target=/mnt/packages \
    install -d /tmp/tf \
    && cp /mnt/packages/terraform-providers.tf /tmp/tf/ \
    && terraform -chdir=/tmp/tf providers mirror -platform=linux_amd64 /usr/local/share/terraform/plugins \
    && find /usr/local/share/terraform/plugins -name 'terraform-provider-*.zip' \
        | sed -E 's#.*/registry\.terraform\.io/([^/]+)/([^/]+)/terraform-provider-[^_]+_([^_]+)_.*#\1/\2 \3#' \
        | LC_ALL=C sort >/terraform-versions.txt
RUN --mount=type=bind,source=packages,target=/mnt/packages \
    packer init /mnt/packages/packer-plugins.pkr.hcl \
    && packer plugins installed \
        | sed -E 's#^.*/plugins/(.+)/packer-plugin-[^_]+_v([^_]+)_.*#\1 \2#' \
        | LC_ALL=C sort >/packer-versions.txt
RUN --mount=type=bind,source=packages,target=/mnt/packages \
    --mount=type=bind,source=build,target=/tmp/build \
    /opt/microsoft/powershell/7/pwsh -NoProfile -NonInteractive \
        -File /tmp/build/pwsh-modules.ps1 /mnt/packages/pwsh-modules.txt >/pwsh-module-versions.txt

# ------------------------------------------------------------------ vscode
# The VS Code server at the commit pinned in packages/vscode.env (the same pin
# the Workstation installer reads), checked against its SHA-256, and the
# extensions in packages/vscode-extensions.txt installed with that server. This
# is where Remote-SSH looks, so attaching downloads nothing. Build time only.
# Remote-SSH has two layouts: the classic bin/<commit>, and the exec-server one
# it defaults to now (the CLI at code-<commit>, which runs the server from
# cli/servers/Stable-<commit>/server). Both are staged: the second links to the
# first, so it costs no space.
FROM ${DHI_BASE} AS vscode
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl jq \
    && rm -rf /var/lib/apt/lists/*
RUN --mount=type=bind,source=packages,target=/mnt/packages \
    set -a && . /mnt/packages/vscode.env && set +a \
    && curl -fsSL -o /tmp/server.tar.gz \
        "https://update.code.visualstudio.com/commit:${VSCODE_COMMIT}/server-linux-x64/stable" \
    && echo "${VSCODE_SERVER_SHA256}  /tmp/server.tar.gz" | sha256sum -c - \
    && server=/home/dev/.vscode-server/bin/${VSCODE_COMMIT} \
    && install -d "$server" \
    && tar -xzf /tmp/server.tar.gz --strip-components 1 -C "$server" \
    && curl -fsSL -o /tmp/cli.tar.gz \
        "https://update.code.visualstudio.com/commit:${VSCODE_COMMIT}/cli-alpine-x64/stable" \
    && echo "${VSCODE_CLI_SHA256}  /tmp/cli.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/cli.tar.gz -C /tmp \
    && install -m 0755 /tmp/code "/home/dev/.vscode-server/code-${VSCODE_COMMIT}" \
    && "/home/dev/.vscode-server/code-${VSCODE_COMMIT}" --version | grep -q "commit ${VSCODE_COMMIT}" \
    && install -d "/home/dev/.vscode-server/cli/servers/Stable-${VSCODE_COMMIT}" \
    && ln -s "../../../bin/${VSCODE_COMMIT}" "/home/dev/.vscode-server/cli/servers/Stable-${VSCODE_COMMIT}/server" \
    && args=() \
    && while read -r p; do args+=(--install-extension "$p"); done \
        < <(grep -vE '^[[:space:]]*(#|$)' /mnt/packages/vscode-extensions.txt) \
    && "$server/bin/code-server" --extensions-dir /home/dev/.vscode-server/extensions "${args[@]}" \
    && jq -r '.[] | "\(.identifier.id) \(.version)"' /home/dev/.vscode-server/extensions/extensions.json \
        | tr '[:upper:]' '[:lower:]' | LC_ALL=C sort >/extensions.txt \
    && while read -r p; do \
        grep -qix "${p%@*} ${p##*@}" /extensions.txt || { echo "pinned $p did not install" >&2; exit 1; }; \
    done < <(grep -vE '^[[:space:]]*(#|$)' /mnt/packages/vscode-extensions.txt) \
    && rm -rf /tmp/server.tar.gz /tmp/cli.tar.gz /tmp/code

# ------------------------------------------------------------------ final
FROM ${DHI_BASE}

ARG DHI_BASE
ARG DEVC_VERSION=0.0.0-local
ARG DEVC_GIT_SHA=local
ARG CODEX_VERSION=0.162.0
ARG TFLINT_VERSION=0.64.0
ARG PWSH_VERSION=7.6.6

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# apt packages from the flat list: DHI's hardened repo, then Debian trixie.
# The base ships no /etc/ld.so.cache, and the VS Code CLI finds libstdc++ only
# through `ldconfig -p`, so the cache is built here. en_US.UTF-8 is the locale
# VS Code terminals set (terminal.integrated.detectLocale).
# hadolint ignore=DL3008
RUN --mount=type=bind,source=packages,target=/mnt/packages \
    apt-get update \
    && grep -vE '^[[:space:]]*(#|$)' /mnt/packages/apt.txt \
        | xargs apt-get install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && localedef -i en_US -f UTF-8 en_US.UTF-8 \
    && ldconfig \
    && install -d /usr/local/bin \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && ln -s /usr/bin/batcat /usr/local/bin/bat

# The dev user (1000:1000). The base has no useradd, so the entries are written
# directly. No sudo, no password, and no setuid or setgid helper left that could
# hand back root.
RUN printf 'dev:x:1000:1000:dev:/home/dev:/bin/bash\n' >>/etc/passwd \
    && printf 'dev:x:1000:\n' >>/etc/group \
    && if [[ -f /etc/shadow ]]; then printf 'dev:!:20000:0:99999:7:::\n' >>/etc/shadow; fi \
    && install -d -o 1000 -g 1000 -m 0755 /home/dev \
    && cp -rT /etc/skel /home/dev \
    && chown -R 1000:1000 /home/dev \
    && install -d -o dev -g dev -m 0755 /home/dev/.local \
    && find / -xdev -perm /6000 -type f -exec chmod a-s {} +

# Tools from the other stages. The real Codex binary sits off PATH:
# /usr/local/bin/codex is the gateway wrapper.
COPY --from=brew-check /out/bin/ /usr/local/bin/
COPY --from=brew-check /out/completions/ /etc/bash_completion.d/
COPY --from=brew-check /out/brew-versions.txt /usr/local/lib/devc/brew-versions.txt
COPY --from=hadolint /bin/hadolint /usr/local/bin/hadolint
COPY --from=downloads /out/bin/ /usr/local/bin/
COPY --from=downloads /out/codex/codex /usr/local/lib/codex/codex
COPY --from=downloads /out/pwsh /opt/microsoft/powershell/7
COPY --from=vscode --chown=1000:1000 /home/dev/.vscode-server /home/dev/.vscode-server
COPY --from=vscode /extensions.txt /usr/local/lib/devc/extensions.txt
COPY --from=python /opt/venv /opt/venv
COPY --from=python /opt/python-wheels /opt/python-wheels
COPY --from=python /usr/share/ansible/collections /usr/share/ansible/collections
COPY --from=caches /usr/local/share/terraform /usr/local/share/terraform
COPY --from=caches /usr/local/share/packer /usr/local/share/packer
COPY --from=caches /usr/local/share/powershell /usr/local/share/powershell
COPY --from=python /python-versions.txt /collection-versions.txt /usr/local/lib/devc/
COPY --from=caches /terraform-versions.txt /packer-versions.txt /pwsh-module-versions.txt /usr/local/lib/devc/
COPY packages/ /usr/local/share/devc/packages/

COPY rootfs/ /
# Every interactive bash runs the image's drop-ins in /etc/bash.bashrc.d, ending
# with Personal Config's bashrc (99-personal.sh).
RUN chmod 0755 /usr/local/bin/* \
    && cat /usr/local/lib/devc/bash.bashrc.append >>/etc/bash.bashrc

# The venv's entry points and pwsh go on PATH through /usr/local/bin, which
# login shells keep (/etc/profile resets PATH).
RUN for f in /opt/venv/bin/ansible* /opt/venv/bin/molecule; do ln -s "$f" /usr/local/bin/; done \
    && ln -s /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh

# Offline by default: no HashiCorp update checks, PowerShell telemetry or
# PowerCLI CEIP; Packer finds its baked plugins.
ENV CHECKPOINT_DISABLE=1 \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off \
    PACKER_PLUGIN_PATH=/usr/local/share/packer/plugins
# $false is PowerShell's, not the shell's.
# hadolint ignore=SC2016
RUN pwsh -NoProfile -NonInteractive -Command \
    'Set-PowerCLIConfiguration -Scope AllUsers -ParticipateInCEIP $false -Confirm:$false | Out-Null'

# The Release MANIFEST as the image knows it. release.sh adds the image ID and
# file checksums to the copy that goes in the archive.
# hadolint ignore=SC2016
RUN --mount=type=bind,source=packages,target=/mnt/packages \
    install -d /etc/devcontainer \
    && { \
        printf 'version: %s\n' "${DEVC_VERSION:?}"; \
        printf 'git_sha: %s\n' "${DEVC_GIT_SHA:?}"; \
        printf 'base: %s\n' "${DHI_BASE}"; \
        printf 'vscode_commit: %s\n' "$(sed -n 's/^VSCODE_COMMIT=//p' /mnt/packages/vscode.env)"; \
        printf '\n## tools\n'; \
        printf 'codex %s\n' "${CODEX_VERSION:?}"; \
        printf 'hadolint %s\n' "$(hadolint --version | awk '{ print $NF }')"; \
        printf 'pwsh %s\n' "${PWSH_VERSION:?}"; \
        printf 'tflint %s\n' "${TFLINT_VERSION:?}"; \
        printf '\n## brew\n'; \
        awk '{ print $1, $2 }' /usr/local/lib/devc/brew-versions.txt | LC_ALL=C sort; \
        printf '\n## apt\n'; \
        grep -vE '^[[:space:]]*(#|$)' /mnt/packages/apt.txt \
            | xargs dpkg-query -W -f '${Package} ${Version}\n' | LC_ALL=C sort; \
        printf '\n## python\n'; \
        cat /usr/local/lib/devc/python-versions.txt; \
        printf '\n## ansible-collections\n'; \
        cat /usr/local/lib/devc/collection-versions.txt; \
        printf '\n## terraform-providers\n'; \
        cat /usr/local/lib/devc/terraform-versions.txt; \
        printf '\n## packer-plugins\n'; \
        cat /usr/local/lib/devc/packer-versions.txt; \
        printf '\n## pwsh-modules\n'; \
        cat /usr/local/lib/devc/pwsh-module-versions.txt; \
        printf '\n## extensions\n'; \
        cat /usr/local/lib/devc/extensions.txt; \
    } >/etc/devcontainer/release

# Trust store: only the public bundle ships. At start devc-entrypoint merges
# Site Config's ca/*.crt into /var/lib/devc/trust as the (capability-less) container user, so the dir is writable by anyone; the system bundle path
# links to the generated store. Keep this after every apt install, since
# update-ca-certificates would replace the link.
RUN install -d /usr/local/share/devc \
    && cp /etc/ssl/certs/ca-certificates.crt /usr/local/share/devc/public-ca-certificates.crt \
    && install -d -m 0777 /var/lib/devc/trust \
    && cp /usr/local/share/devc/public-ca-certificates.crt /var/lib/devc/trust/ca-certificates.crt \
    && ln -sf /var/lib/devc/trust/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

# The non-root sshd (devc-sshd): the Roster's key list is mounted at
# /etc/devc/authorized_keys and the host key lives on the admin's volume.
RUN install -d /etc/devc \
    && install -d -o dev -g dev -m 0700 /var/lib/devc/hostkeys
EXPOSE 2222

USER dev
WORKDIR /home/dev
ENTRYPOINT ["/usr/local/bin/devc-entrypoint"]
CMD ["devc-sshd"]
