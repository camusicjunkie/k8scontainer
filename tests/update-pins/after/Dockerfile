# Fixture for tests/update-pins.py: the pin lines of image/Dockerfile.
ARG DHI_BASE=dhi.io/debian-base:trixie-dev@sha256:120051dda16c2611454d2c54a0959f23f80c32493d0e528a5d1348bca82dfbc8
ARG BREW_IMAGE=ghcr.io/homebrew/brew:7.0.16@sha256:af4248b6688e954119fc2f61fbd8a26ea85d309df91ac065913d423c57a04549
ARG HADOLINT_IMAGE=docker.io/hadolint/hadolint:v2.15.1-debian@sha256:9a3944b7fddcb947d1ffd90829ac1a6e5c30479223358f249d8b96c7d0019e27
ARG CODEX_VERSION=0.172.0
ARG CODEX_SHA256=a2342a8f7f68f088be30620ccfe9cb84162c93a6b56177855961cda3ed6be392
ARG TFLINT_VERSION=0.66.0
ARG TFLINT_SHA256=22be11cadc25cd02401e94c0ccc91aa63467debb8485c2a755d98f4c0a9d1e2e
ARG PWSH_VERSION=7.7.0
ARG PWSH_SHA256=c89d9c682d2c403dfe726f3df948e359675235a5bd6fab535776de69729ca0cb

FROM ${DHI_BASE} AS downloads
ADD --checksum=sha256:${CODEX_SHA256} \
    https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-x86_64-unknown-linux-musl.tar.gz \
    /tmp/codex.tar.gz
ADD --checksum=sha256:${TFLINT_SHA256} \
    https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_amd64.zip \
    /tmp/tflint.zip
ADD --checksum=sha256:${PWSH_SHA256} \
    https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz \
    /tmp/pwsh.tar.gz
