# 08: Secrets File and `klogin` in the Pod

**What to build:** An admin creates and unlocks their Secrets File inside the Pod using the forwarded smartcard agent, then logs in to a Supervisor or Guest Cluster with `klogin`.

**Blocked by:** 06

**Status:** ready-for-agent

- [ ] Creating the Secrets File succeeds only with an RSA PIV Authentication key whose signatures repeat
- [ ] The Secrets File unlocks in a Remote-SSH terminal with the agent forwarded and refuses without it
- [ ] `klogin` logs in to a Supervisor and a Guest Cluster using the Site Config targets, and the logins survive a Pod restart
- [ ] A clear message appears when the agent is not forwarded
