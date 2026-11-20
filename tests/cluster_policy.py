#!/usr/bin/env python3
"""Cluster seam, policy half: reads the rendered manifests (YAML on stdin, as
`kubectl kustomize manifests/devcontainer` prints them) and checks what the
Management Cluster would enforce on them. Stands in for the Gitops repository's
Kyverno policies, which are not available here: it asserts the Pod Security
`restricted` fields (Kubernetes 1.31 profile) and the ticket's behaviours.

    kubectl kustomize manifests/devcontainer | python3 tests/cluster_policy.py
"""
import sys

import yaml

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
failed = []


def check(desc, ok):
    print(("ok   " if ok else "FAIL ") + desc)
    if not ok:
        failed.append(desc)


def of(kind):
    return [d for d in docs if d["kind"] == kind]


ns = (of("Namespace") or [None])[0]
sts = (of("StatefulSet") or [None])[0]
check("renders a Namespace and a StatefulSet", ns is not None and sts is not None)
if ns is None or sts is None:
    sys.exit(1)

labels = ns["metadata"].get("labels", {})
check("namespace enforces Pod Security restricted", labels.get("pod-security.kubernetes.io/enforce") == "restricted")
check("namespace joins Istio ambient", labels.get("istio.io/dataplane-mode") == "ambient")
check("every namespaced object is in the Devcontainer Namespace",
      all(d["metadata"].get("namespace") == ns["metadata"]["name"] for d in docs if d["kind"] != "Namespace"))

spec = sts["spec"]
pod = spec["template"]["spec"]
check("one replica", spec["replicas"] == 1)
check("OnDelete update strategy", spec["updateStrategy"]["type"] == "OnDelete")
check("serviceName is set", bool(spec.get("serviceName")))

c = pod["containers"][0]
host, _, rest = c["image"].partition("/")
tag = c["image"].rsplit(":", 1)[-1] if ":" in rest else ""
check("image comes from a Registry host, not Docker Hub", "." in host and host != "docker.io")
check("image is pinned to a tag other than latest", tag not in ("", "latest"))

# Pod Security restricted
psc = pod.get("securityContext", {})
sc = c.get("securityContext", {})
check("pod runs as non-root", psc.get("runAsNonRoot") is True or sc.get("runAsNonRoot") is True)
check("no container runs as uid 0", all(x.get("securityContext", {}).get("runAsUser", psc.get("runAsUser", 1)) != 0
                                       for x in pod["containers"] + pod.get("initContainers", [])))
check("seccomp RuntimeDefault", (psc.get("seccompProfile") or sc.get("seccompProfile") or {}).get("type") == "RuntimeDefault")
check("privilege escalation disallowed", sc.get("allowPrivilegeEscalation") is False)
check("all capabilities dropped, none added", sc.get("capabilities", {}).get("drop") == ["ALL"] and not sc.get("capabilities", {}).get("add"))
check("not privileged", not sc.get("privileged"))
check("no host namespaces", not any(pod.get(k) for k in ("hostNetwork", "hostPID", "hostIPC")))
check("only restricted volume types", all(set(v) - {"name"} <= {"configMap", "secret", "emptyDir", "projected", "persistentVolumeClaim", "downwardAPI", "csi", "ephemeral"}
                                          for v in pod.get("volumes", [])))
check("no host ports", not any("hostPort" in p for p in c.get("ports", [])))

# Volume layout
want = {"workspace": "/home/dev/workspace", ".kube": "/home/dev/.kube", ".secrets": "/home/dev/.secrets",
        ".devc/personal": "/home/dev/.devc/personal", "hostkeys": "/var/lib/devc/hostkeys", ".local": "/home/dev/.local"}
claims = {t["metadata"]["name"]: t for t in spec.get("volumeClaimTemplates", [])}
check("one State Directory claim, 20Gi on standard, ReadWriteOnce",
      len(claims) == 1 and all(t["spec"]["storageClassName"] == "standard"
                               and t["spec"]["resources"]["requests"]["storage"] == "20Gi"
                               and t["spec"]["accessModes"] == ["ReadWriteOnce"] for t in claims.values()))
state = next(iter(claims), None)
mounts = {m["mountPath"]: m for m in c["volumeMounts"] if m["name"] == state}
check("the volume is mounted at exactly the six listed paths", set(mounts) == set(want.values()))
check("each mount takes its own subPath of the volume", {m.get("subPath"): p for p, m in mounts.items()} == want)

# Site Config
site = [m for m in c["volumeMounts"] if m["name"] != state and m["mountPath"].startswith("/etc/devcontainer/site")]
check("Site Config is mounted read-only", bool(site) and all(m.get("readOnly") is True for m in site))
ca = [m for m in site if m["mountPath"].startswith("/etc/devcontainer/site/ca/") and m["mountPath"].endswith(".crt")]
check("Site Config CAs land as ca/*.crt single files (subPath): the image rejects symlinks, which a ConfigMap directory mount is made of",
      bool(ca) and all(m.get("subPath") for m in ca))
vols = {v["name"]: v for v in pod["volumes"]}
cm_names = {d["metadata"]["name"] for d in of("ConfigMap")}
check("Site Config comes from a ConfigMap in the manifests",
      bool(site) and all("configMap" in vols[m["name"]] and vols[m["name"]]["configMap"]["name"] in cm_names for m in site))
cm = next((d for d in of("ConfigMap") if ca and d["metadata"]["name"] == vols[ca[0]["name"]]["configMap"]["name"]), None)
check("each mounted CA key exists in the ConfigMap and holds a certificate",
      cm is not None and all("BEGIN CERTIFICATE" in cm["data"].get(m["subPath"], "") for m in ca))

# sshd and resources
check("sshd port 2222 is exposed", any(p["containerPort"] == 2222 for p in c.get("ports", [])))
r = c.get("resources", {})
check("requests and limits both set", {"cpu", "memory"} <= set(r.get("requests", {})) and {"cpu", "memory"} <= set(r.get("limits", {})))
check("pod fsGroup lets uid 1000 write the volume", psc.get("fsGroup") == 1000)

# Gateway exposure (ticket 06). The admin's details are hard-coded until the Roster.
ADMIN_PORT = 2201
gw = (of("Gateway") or [None])[0]
check("renders a Gateway", gw is not None)
lis = [l for l in (gw or {}).get("spec", {}).get("listeners", []) if l.get("protocol") == "TCP"]
check("Gateway has a TCP listener on the admin's port", any(l["port"] == ADMIN_PORT for l in lis))
check("Gateway listener admits only Routes from its own namespace",
      bool(lis) and all(l.get("allowedRoutes", {}).get("namespaces", {}).get("from") == "Same" for l in lis))
route = (of("TCPRoute") or [None])[0]
check("renders a TCPRoute", route is not None)
if gw and route:
    ref = route["spec"]["parentRefs"][0]
    sect = next((l for l in lis if l["name"] == ref.get("sectionName")), None)
    check("TCPRoute attaches to the Gateway listener on the admin's port",
          ref["name"] == gw["metadata"]["name"] and sect is not None and sect["port"] == ADMIN_PORT)
    be = route["spec"]["rules"][0]["backendRefs"][0]
    svc = next((d for d in of("Service") if d["metadata"]["name"] == be["name"]), None)
    check("TCPRoute backend is a Service in the manifests, on the sshd port",
          svc is not None and be["port"] == 2222 and any(p["port"] == 2222 for p in svc["spec"]["ports"]))
    check("the backend Service selects the admin's Pod and is not headless (ClusterIP)",
          svc is not None and svc["spec"].get("clusterIP") != "None"
          and all(sts["spec"]["template"]["metadata"]["labels"].get(k) == v for k, v in svc["spec"]["selector"].items()))

# Key list: mounted from a ConfigMap at /etc/devc/authorized_keys
km = [m for m in c["volumeMounts"] if m["mountPath"] == "/etc/devc/authorized_keys"]
check("the key list is mounted read-only as the single file /etc/devc/authorized_keys",
      len(km) == 1 and km[0].get("readOnly") is True and bool(km[0].get("subPath")))
kcm = next((d for d in of("ConfigMap") if km and vols.get(km[0]["name"], {}).get("configMap", {}).get("name") == d["metadata"]["name"]), None)
keys = [l for l in (kcm or {}).get("data", {}).get(km[0]["subPath"] if km else "", "").splitlines() if l.strip() and not l.startswith("#")]
check("the key list holds at least one public key and no private key",
      bool(keys) and all(l.split()[0].startswith(("ssh-", "ecdsa-", "sk-")) for l in keys)
      and "PRIVATE KEY" not in str(kcm))
check("the Pod has no Kubernetes API credentials", pod.get("automountServiceAccountToken") is False)

sys.exit(1 if failed else 0)
