# 01: One version per downloaded tool

**What to build:** Each downloaded tool's version (Codex, tflint, pwsh) is defined once in `image/Dockerfile`. Today the `downloads` stage (lines 39–44) and the final stage (lines 193–195) each give `CODEX_VERSION`, `TFLINT_VERSION` and `PWSH_VERSION` a default, so a bump that changes one builds one version and records the other in the MANIFEST.

**Blocked by:** none

**Status:** resolved

- [x] Each of `CODEX_VERSION`, `TFLINT_VERSION` and `PWSH_VERSION` has its value in one place in `image/Dockerfile`, and every stage that needs it reads that one
- [x] `tests/repo.py` fails when a downloaded tool's version or checksum is given a value more than once
- [x] The MANIFEST still records each tool's version (`tests/image.sh` passes)

## Comments

**Done (2026-11-26):** The six pins (`CODEX_*`, `TFLINT_*`, `PWSH_*`, versions and SHA-256s) are now global ARGs at the top of `image/Dockerfile`, next to the base image digests. The `downloads` and final stages read them with a bare `ARG <name>`, so a `--build-arg` still overrides both stages together. `tests/repo.py` now fails when any build arg is given a value more than once. That's broader than the three tools, and nothing else in the Dockerfile gives a value twice. Run against the old Dockerfile, it failed and named `CODEX_VERSION, PWSH_VERSION, TFLINT_VERSION`. `tests/all.sh --files` passes. `tests/image.sh` passes. In the built image, the MANIFEST's `## tools` lines (`codex 0.162.0`, `pwsh 7.6.6`, `tflint 0.64.0`) match `codex --version`, `pwsh --version` and `tflint --version`.
