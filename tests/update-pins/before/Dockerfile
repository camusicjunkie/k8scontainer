# Fixture for tests/update-pins.py: the pin lines of image/Dockerfile.
ARG DHI_BASE=dhi.io/debian-base:trixie-dev@sha256:f90fd43cdf3dd94840b4dc3a2a39fd2a08578e40e7895535e2e20a1275ba6013
ARG BREW_IMAGE=ghcr.io/homebrew/brew:4.6.20@sha256:b0072bfdebf5934ae24b93b44a1928a88057399b3283ffa0177bb86084fdedfd
ARG HADOLINT_IMAGE=docker.io/hadolint/hadolint:v2.15.1-debian@sha256:9a3944b7fddcb947d1ffd90829ac1a6e5c30479223358f249d8b96c7d0019e27
ARG CODEX_VERSION=0.162.0
ARG CODEX_SHA256=8daf67f6261161aa5939d8d42a516032d760406216779d7ce6040f242140ff73
ARG TFLINT_VERSION=0.64.0
ARG TFLINT_SHA256=cca9d13e2e1d7a2c627af60ff899a3c9b74212899416aeb96ec764d2ef954537
ARG PWSH_VERSION=7.6.6
ARG PWSH_SHA256=ddbc4a2d113bbd46d283cfedcbcd117a70caefd7673f41f2b4e0000badf103bc

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
