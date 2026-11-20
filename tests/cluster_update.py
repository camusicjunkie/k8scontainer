#!/usr/bin/env python3
"""Cluster seam, update half: the image update flow (ticket 10).

    python3 tests/cluster_update.py ROSTER_FILE OLD.yaml NEW.yaml

ROSTER_FILE is the committed manifests/devcontainer/roster.yaml, read as text
because the marker is a comment. OLD.yaml and NEW.yaml are the rendered
output (as in cluster.sh) for two Rosters that differ only in `image`: the
earlier tag and the later tag. Checks, from outside:
  - the Roster's single image line carries the marker the Management Cluster's
    image automation rewrites, naming an ImagePolicy that is rendered here and
    selects by semver over the Registry repository the image comes from;
  - changing the tag changes the Pod template image and nothing else, so with
    OnDelete a running Pod is not restarted and its volume claim is unchanged;
  - pinning an earlier tag renders (OLD is the pinned-back case of NEW).
"""
import json
import re
import sys

import yaml

roster_text = open(sys.argv[1], encoding="utf-8").read()
old = [d for d in yaml.safe_load_all(open(sys.argv[2], encoding="utf-8")) if d]
new = [d for d in yaml.safe_load_all(open(sys.argv[3], encoding="utf-8")) if d]
failed = []


def check(desc, ok):
    print(("ok   " if ok else "FAIL ") + desc)
    if not ok:
        failed.append(desc)


# The marker: exactly one image line in the Roster, with a setter comment.
lines = [l for l in roster_text.splitlines() if re.match(r"\s+image:\s", l)]
check("the Roster has exactly one image value", len(lines) == 1)
m = re.match(r"\s+image:\s+(\S+)\s+#\s*(\{.*\})\s*$", lines[0]) if lines else None
check("the image value carries an image-automation marker", m is not None)
policy_ref = None
if m:
    ref, marker = m.group(1), json.loads(m.group(2))
    policy_ref = marker.get("$imagepolicy")
    check("the marker is a whole-image $imagepolicy setter (namespace:name)",
          list(marker) == ["$imagepolicy"] and bool(re.fullmatch(r"[a-z0-9-]+:[a-z0-9-]+", policy_ref or "")))

if policy_ref:
    ns, name = policy_ref.split(":")
    pol = next((d for d in new if d["kind"] == "ImagePolicy" and d["metadata"]["name"] == name
                and d["metadata"]["namespace"] == ns), None)
    check("the marker names an ImagePolicy rendered in the same place", pol is not None)
    if pol:
        check("the policy selects by semver, not by date or name",
              set(pol["spec"]["policy"]) == {"semver"} and bool(pol["spec"]["policy"]["semver"]["range"]))
        check("the semver range excludes pre-release tags (only Release tags are chosen)",
              "-" not in pol["spec"]["policy"]["semver"]["range"])
        repo = next((d for d in new if d["kind"] == "ImageRepository"
                     and d["metadata"]["name"] == pol["spec"]["imageRepositoryRef"]["name"]), None)
        check("the policy scans an ImageRepository for the Standard Image's own Registry repository",
              repo is not None and repo["spec"]["image"] == ref.rsplit(":", 1)[0])
        check("the repository is scanned on an interval", repo is not None and bool(repo["spec"].get("interval")))


def sts(docs):
    s = [d for d in docs if d["kind"] == "StatefulSet"]
    return s[0] if len(s) == 1 else None


a, b = sts(old), sts(new)
check("each rendering has its StatefulSet", a is not None and b is not None)
if a and b:
    ia = a["spec"]["template"]["spec"]["containers"][0]["image"]
    ib = b["spec"]["template"]["spec"]["containers"][0]["image"]
    check(f"changing the tag changes the Pod template image ({ia} -> {ib})",
          ia != ib and ia.rsplit(":", 1)[0] == ib.rsplit(":", 1)[0])
    check("both use OnDelete, so the update does not restart a running Pod",
          a["spec"]["updateStrategy"]["type"] == "OnDelete" == b["spec"]["updateStrategy"]["type"])

    def scrub(s):
        s = json.loads(json.dumps(s))
        s["spec"]["template"]["spec"]["containers"][0]["image"] = "X"
        return s
    check("the tag is the only difference between the two StatefulSets", scrub(a) == scrub(b))
    check("the volume claim template is identical, so the admin's volume is the same after a restart",
          a["spec"]["volumeClaimTemplates"] == b["spec"]["volumeClaimTemplates"])
    check("other generated objects are unaffected by the tag",
          [d for d in old if d["kind"] != "StatefulSet"] == [d for d in new if d["kind"] != "StatefulSet"])

sys.exit(1 if failed else 0)
