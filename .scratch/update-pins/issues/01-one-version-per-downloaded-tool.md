# 01: One version per downloaded tool

**What to build:** Each downloaded tool's version (Codex, tflint, pwsh) is defined once in `image/Dockerfile`. Today the `downloads` stage (lines 39–44) and the final stage (lines 193–195) each give `CODEX_VERSION`, `TFLINT_VERSION` and `PWSH_VERSION` a default, so a bump that changes one builds one version and records the other in the MANIFEST.

**Blocked by:** none

**Status:** ready-for-agent

- [ ] Each of `CODEX_VERSION`, `TFLINT_VERSION` and `PWSH_VERSION` has its value in one place in `image/Dockerfile`, and every stage that needs it reads that one
- [ ] `tests/repo.py` fails when a downloaded tool's version or checksum is given a value more than once
- [ ] The MANIFEST still records each tool's version (`tests/image.sh` passes)
