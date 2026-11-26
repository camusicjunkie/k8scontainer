# 04: Rotate the DHI token that went through the chat

**What to build:** On 2026-11-20 the DHI password was typed into a Claude Code session while setting `DHI_PASSWORD` on the local GitLab. It is now in plain text in that session's log on the workstation. Replace the token, and write down how to set CI secrets so a secret never passes through a chat or a command line.

**Blocked by:** None (can start immediately)

**Status:** ready-for-human

- [ ] A new DHI token is issued and the old one is revoked
- [ ] `DHI_PASSWORD` on the local GitLab and the Docker login on each build host use the new token
- [ ] The old session log is deleted or the token is redacted from it
- [ ] The Release Owner guide says to set CI secrets from a file or a prompt (`glab variable set NAME < file`), never on a command line or in a chat
