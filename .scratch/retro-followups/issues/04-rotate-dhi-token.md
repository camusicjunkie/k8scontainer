# 04: Rotate the DHI token that went through the chat

**What to build:** On 2026-11-20 the DHI password was typed into a Claude Code session while setting `DHI_PASSWORD` on the local GitLab. It is now in plain text in that session's log on the workstation. Replace the token, and write down how to set CI secrets so a secret never passes through a chat or a command line.

**Blocked by:** None (can start immediately)

**Status:** ready-for-human

- [x] A new DHI token is issued and the old one is revoked
- [x] `DHI_PASSWORD` on the local GitLab and the Docker login on each build host use the new token
- [ ] The old session log is deleted or the token is redacted from it
- [x] The Release Owner guide says to set CI secrets from a file or a prompt (`glab variable set NAME < file`), never on a command line or in a chat

## Comments

**Found (2026-11-27):** what leaked was the Docker account password itself, not an access token, set with `! glab variable set DHI_PASSWORD "<value>"`. It was in plain text in two session logs under `~/.claude/projects/D--Docker-k8scontainer/` (2f668b55, 14 copies; 57b94988, 3) and, from a scan that failed to mask it, in session f010f26c. Not in the repository's history (checked 2026-11-27).

**Done (2026-11-27):**

- Redacted in place (`[REDACTED-DHI-PASSWORD]`) in 2f668b55 and 57b94988, by a script that reads the value from a log rather than taking it on a command line. Session f010f26c was still being written, so it still holds 3 copies: the script is run on it after that session ends.
- A new Docker access token, Repo Read-only, issued by the Release Owner and saved to a file, never shown in the chat. `DHI_PASSWORD` on the local GitLab updated from the file (masked; 36 characters, `dckr_` prefix, checked through the API without printing the value). This workstation's `docker login dhi.io` uses it; `docker buildx imagetools inspect` on the DHI base succeeded against the registry. The file is deleted. This workstation is the only build host so far.
- `docs/release-owner-guide.md`, "One-time setup": DHI_PASSWORD is a Repo Read-only access token with an expiry, and secrets are set from a file on stdin, never on a command line or in a chat.
- The older access tokens are deleted (Release Owner, 2026-11-27).
- **Decision:** the item about revoking the old credential is ticked on the Release Owner's word (2026-11-27) that the Docker account password, the value that leaked, is changed at the start of that workday. The old access tokens are deleted, and a stale `https://dhi.io` login holding one of them is removed from this workstation's credential store.
- Open, for the Release Owner: after session f010f26c ends, run `scratchpad/redact_dhi.py --source f010f26c-5c57-4e89-badb-dbd777514459 --apply`.
