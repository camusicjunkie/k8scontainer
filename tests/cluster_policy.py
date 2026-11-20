#!/usr/bin/env python3
"""Cluster seam, policy half: reads the rendered manifests (YAML on stdin) and
checks what the Management Cluster would enforce on them. Stands in for the
Gitops repository's Kyverno policies, which are not available here: it asserts
the Pod Security `restricted` fields (Kubernetes 1.31 profile) and the
tickets' behaviours.

The input is the Namespace and Site Config (`kubectl kustomize
manifests/devcontainer`) followed by what the ResourceSet generates for a
Roster (`flux-operator build resourceset`). The Roster file names who must be
there, and everything per admin is checked for every admin in it:

    python3 tests/cluster_policy.py ROSTER.yaml <rendered.yaml
"""
import sys

import yaml

roster = yaml.safe_load(open(sys.argv[1]))["spec"]["defaultValues"]["admins"]
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
failed = []

DEFAULT_RESOURCES = {"requests": {"cpu": "250m", "memory": "512Mi"}, "limits": {"cpu": "2", "memory": "4Gi"}}
WANT_PATHS = {"workspace": "/home/dev/workspace", ".kube": "/home/dev/.kube", ".secrets": "/home/dev/.secrets",
              ".devc/personal": "/home/dev/.devc/personal", "hostkeys": "/var/lib/devc/hostkeys",
              ".local": "/home/dev/.local"}


def check(desc, ok):
    print(("ok   " if ok else "FAIL ") + desc)
    if not ok:
        failed.append(desc)


def of(kind):
    return [d for d in docs if d["kind"] == kind]


def named(kind, name):
    return next((d for d in of(kind) if d["metadata"]["name"] == name), None)


ns = (of("Namespace") or [None])[0]
check("renders a Namespace", ns is not None)
if ns is None:
    sys.exit(1)
labels = ns["metadata"].get("labels", {})
check("namespace enforces Pod Security restricted", labels.get("pod-security.kubernetes.io/enforce") == "restricted")
check("namespace joins Istio ambient", labels.get("istio.io/dataplane-mode") == "ambient")
check("every namespaced object is in the Devcontainer Namespace",
      all(d["metadata"].get("namespace") == ns["metadata"]["name"] for d in docs if d["kind"] != "Namespace"))
check("nothing from the Roster machinery itself is rendered as a workload", not of("ResourceSet"))

names = [a["name"] for a in roster]
ports = [a["port"] for a in roster]
check("the Roster's names and ports are each unique", len(set(names)) == len(names) and len(set(ports)) == len(ports))
sts_all = of("StatefulSet")
check("one StatefulSet per Roster entry and no others", sorted(s["metadata"]["name"] for s in sts_all) == sorted(f"devc-{n}" for n in names))

gw = (of("Gateway") or [None])[0]
check("renders exactly one shared Gateway", gw is not None and len(of("Gateway")) == 1)
lis = [l for l in (gw or {}).get("spec", {}).get("listeners", []) if l.get("protocol") == "TCP"]
check("the Gateway has exactly one TCP listener per Roster entry, on the Roster's ports",
      sorted(l["port"] for l in lis) == sorted(ports) and len(lis) == len(gw["spec"]["listeners"]))
check("every Gateway listener admits only Routes from its own namespace",
      bool(lis) and all(l.get("allowedRoutes", {}).get("namespaces", {}).get("from") == "Same" for l in lis))
check("one TCPRoute per Roster entry and no others", len(of("TCPRoute")) == len(roster))

per_admin = {}
for a in roster:
    n = a["name"]
    print(f"-- admin {n}")
    sts = named("StatefulSet", f"devc-{n}")
    check(f"[{n}] renders a StatefulSet", sts is not None)
    if sts is None:
        continue
    spec = sts["spec"]
    pod = spec["template"]["spec"]
    c = pod["containers"][0]
    psc = pod.get("securityContext", {})
    sc = c.get("securityContext", {})

    check(f"[{n}] one replica, OnDelete update strategy, serviceName set",
          spec["replicas"] == 1 and spec["updateStrategy"]["type"] == "OnDelete" and bool(spec.get("serviceName")))
    host, _, rest = c["image"].partition("/")
    tag = c["image"].rsplit(":", 1)[-1] if ":" in rest else ""
    check(f"[{n}] image comes from a Registry host, pinned to a tag other than latest",
          "." in host and host != "docker.io" and tag not in ("", "latest"))

    # Pod Security restricted
    check(f"[{n}] pod runs as non-root, no container as uid 0",
          (psc.get("runAsNonRoot") is True or sc.get("runAsNonRoot") is True)
          and all(x.get("securityContext", {}).get("runAsUser", psc.get("runAsUser", 1)) != 0
                  for x in pod["containers"] + pod.get("initContainers", [])))
    check(f"[{n}] seccomp RuntimeDefault", (psc.get("seccompProfile") or sc.get("seccompProfile") or {}).get("type") == "RuntimeDefault")
    check(f"[{n}] no privilege escalation, all capabilities dropped, not privileged",
          sc.get("allowPrivilegeEscalation") is False and sc.get("capabilities", {}).get("drop") == ["ALL"]
          and not sc.get("capabilities", {}).get("add") and not sc.get("privileged"))
    check(f"[{n}] no host namespaces or host ports",
          not any(pod.get(k) for k in ("hostNetwork", "hostPID", "hostIPC")) and not any("hostPort" in p for p in c.get("ports", [])))
    check(f"[{n}] only restricted volume types",
          all(set(v) - {"name"} <= {"configMap", "secret", "emptyDir", "projected", "persistentVolumeClaim", "downwardAPI", "csi", "ephemeral"}
              for v in pod.get("volumes", [])))
    check(f"[{n}] the Pod has no Kubernetes API credentials", pod.get("automountServiceAccountToken") is False)
    check(f"[{n}] pod fsGroup lets uid 1000 write the volume", psc.get("fsGroup") == 1000)
    check(f"[{n}] sshd port 2222 is exposed", any(p["containerPort"] == 2222 for p in c.get("ports", [])))

    # Volume layout
    claims = {t["metadata"]["name"]: t for t in spec.get("volumeClaimTemplates", [])}
    check(f"[{n}] one State Directory claim, 20Gi on standard, ReadWriteOnce",
          len(claims) == 1 and all(t["spec"]["storageClassName"] == "standard"
                                   and t["spec"]["resources"]["requests"]["storage"] == "20Gi"
                                   and t["spec"]["accessModes"] == ["ReadWriteOnce"] for t in claims.values()))
    state = next(iter(claims), None)
    mounts = {m["mountPath"]: m for m in c["volumeMounts"] if m["name"] == state}
    check(f"[{n}] the volume is mounted at exactly the six listed paths, each its own subPath",
          {m.get("subPath"): p for p, m in mounts.items()} == WANT_PATHS)

    # Site Config
    vols = {v["name"]: v for v in pod["volumes"]}
    site = [m for m in c["volumeMounts"] if m["mountPath"].startswith("/etc/devcontainer/site")]
    check(f"[{n}] Site Config is mounted read-only", bool(site) and all(m.get("readOnly") is True for m in site))
    ca = [m for m in site if m["mountPath"].startswith("/etc/devcontainer/site/ca/") and m["mountPath"].endswith(".crt")]
    check(f"[{n}] Site Config CAs land as ca/*.crt single files (subPath): the image rejects symlinks, which a ConfigMap directory mount is made of",
          bool(ca) and all(m.get("subPath") for m in ca))
    check(f"[{n}] Site Config comes from the shared site-config ConfigMap",
          bool(site) and all(vols[m["name"]].get("configMap", {}).get("name") == "site-config" for m in site)
          and named("ConfigMap", "site-config") is not None)
    cm = named("ConfigMap", "site-config")
    check(f"[{n}] each mounted CA key exists in the ConfigMap and holds a certificate",
          cm is not None and all("BEGIN CERTIFICATE" in cm["data"].get(m["subPath"], "") for m in ca))

    # Resources, with the Roster's overrides
    want = {k: {**DEFAULT_RESOURCES[k], **a.get("resources", {}).get(k, {})} for k in DEFAULT_RESOURCES}
    check(f"[{n}] requests and limits are the defaults with the Roster's overrides applied", c.get("resources") == want)

    # Key list: this admin's own ConfigMap, holding exactly the Roster's key
    km = [m for m in c["volumeMounts"] if m["mountPath"] == "/etc/devc/authorized_keys"]
    check(f"[{n}] the key list is mounted read-only as the single file /etc/devc/authorized_keys",
          len(km) == 1 and km[0].get("readOnly") is True and bool(km[0].get("subPath")))
    kname = vols.get(km[0]["name"], {}).get("configMap", {}).get("name") if km else None
    kcm = named("ConfigMap", kname) if kname else None
    keys = [l for l in (kcm or {}).get("data", {}).get(km[0]["subPath"] if km else "", "").splitlines() if l.strip() and not l.startswith("#")]
    check(f"[{n}] the key list is exactly the Roster's public key and no private key",
          keys == [a["publicKey"].strip()] and "PRIVATE KEY" not in str(kcm))

    # Exposure: this admin's listener -> route -> Service -> this Pod only
    sect = next((l for l in lis if l["name"] == f"ssh-{n}"), None)
    check(f"[{n}] has a Gateway listener on port {a['port']}", sect is not None and sect["port"] == a["port"])
    route = named("TCPRoute", f"devc-{n}-ssh")
    check(f"[{n}] has a TCPRoute attached to its own listener",
          route is not None and gw is not None and len(route["spec"]["parentRefs"]) == 1
          and route["spec"]["parentRefs"][0]["name"] == gw["metadata"]["name"]
          and route["spec"]["parentRefs"][0].get("sectionName") == f"ssh-{n}")
    be = route["spec"]["rules"][0]["backendRefs"][0] if route else {}
    svc = named("Service", be.get("name", ""))
    plabels = sts["spec"]["template"]["metadata"]["labels"]
    check(f"[{n}] the route's backend is a ClusterIP Service on the sshd port selecting this Pod",
          svc is not None and be.get("port") == 2222 and any(p["port"] == 2222 for p in svc["spec"]["ports"])
          and svc["spec"].get("clusterIP") != "None"
          and all(plabels.get(k) == v for k, v in svc["spec"]["selector"].items()))
    check(f"[{n}] the route has a single backend and the Service selects by this admin's own label",
          route is not None and len(route["spec"]["rules"]) == 1 and len(route["spec"]["rules"][0]["backendRefs"]) == 1
          and svc is not None and svc["spec"]["selector"].get("devcontainer/admin") == n)
    headless = named("Service", spec["serviceName"])
    check(f"[{n}] the StatefulSet's governing Service is headless and selects this Pod",
          headless is not None and headless["spec"].get("clusterIP") == "None"
          and all(plabels.get(k) == v for k, v in headless["spec"]["selector"].items()))

    per_admin[n] = {"sts": sts, "claim": state, "kcm": kname, "port": a["port"], "listener": f"ssh-{n}",
                    "selector": svc["spec"]["selector"] if svc else {},
                    "pvcs": {c2["name"] for c2 in pod["volumes"] if "persistentVolumeClaim" in c2},
                    "cms": {v["configMap"]["name"] for v in pod["volumes"] if "configMap" in v}}

# Isolation between admins
print("-- isolation")
if len(per_admin) > 1:
    def distinct(desc, vals):
        vals = list(vals)
        check(desc, len(vals) == len(set(vals)))
    distinct("Pod (StatefulSet) names are distinct", (p["sts"]["metadata"]["name"] for p in per_admin.values()))
    distinct("volume claim names, once per-Pod, are distinct",
             (f"{p['claim']}-{p['sts']['metadata']['name']}-0" for p in per_admin.values()))
    distinct("key list ConfigMap names are distinct", (p["kcm"] for p in per_admin.values()))
    distinct("Gateway ports are distinct", (p["port"] for p in per_admin.values()))
    distinct("Pod selectors are distinct", (str(sorted(p["selector"].items())) for p in per_admin.values()))
for n, p in per_admin.items():
    others = [q for m, q in per_admin.items() if m != n]
    owned = {f"devc-{n}-authorized-keys", "site-config"}
    check(f"[{n}] the Pod mounts only its own key list and the shared Site Config, never another admin's",
          p["cms"] == owned)
    check(f"[{n}] the Pod references no persistent volume claim directly (only its own claim template)", not p["pvcs"])
    other_text = " ".join(str(q["sts"]) for q in others)
    own_pub = next(a["publicKey"] for a in roster if a["name"] == n)
    check(f"[{n}] its key does not appear in any other admin's Pod, and no other admin's name or key appears in its Pod",
          own_pub not in other_text and all(m == n or (f"devc-{m}" not in str(p["sts"]) and a2["publicKey"] not in str(p["sts"]))
                                            for m in per_admin for a2 in roster if a2["name"] == m))
    other_kcm = [named("ConfigMap", q["kcm"]) for q in others]
    check(f"[{n}] its key is not in any other admin's key list", all(own_pub not in str(k) for k in other_kcm))

sys.exit(1 if failed else 0)
