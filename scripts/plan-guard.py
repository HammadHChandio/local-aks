"""Classify a `terraform show -json` plan against terraform/tests/known-emulator-drift.json.

Output (stdout, JSON): {"real": [...addresses], "emulator": [...], "cascade": [...], "details": {...}}
A change is 'emulator' only if its action matches the deviation AND every changed/replace path is listed.
A change is 'cascade' only if it is listed as a cascade of an emulator deviation present in this plan and
its replace paths are limited to the parent reference. Everything else is 'real'.
usage: plan-guard.py <plan.json> <known.json>
"""
import json
import sys

plan = json.load(open(sys.argv[1]))
known = {d["address"]: d for d in json.load(open(sys.argv[2]))["deviations"]}
PARENT_REFS = {"server_id", "target_resource_id", "kubernetes_cluster_id"}


def kind(actions):
    if actions in (["no-op"], ["read"]):
        return None
    if actions == ["update"]:
        return "update"
    if sorted(actions) == ["create", "delete"]:
        return "replace"
    return "+".join(actions)


def changed_attrs(ch):
    b, a = ch.get("before") or {}, ch.get("after") or {}
    unk = ch.get("after_unknown") or {}
    return sorted(k for k in set(a) | set(b) if b.get(k) != a.get(k) and not (k in unk and k not in b))


out = {"real": [], "emulator": [], "cascade": [], "details": {}}
changes = [(rc["address"], kind(rc["change"]["actions"]), rc["change"]) for rc in plan.get("resource_changes", [])]
changes = [c for c in changes if c[1]]
emulator_parents = set()
for addr, k, ch in changes:
    paths = sorted({p[0] for p in ch.get("replace_paths") or []}) if k == "replace" else changed_attrs(ch)
    out["details"][addr] = {"action": k, "paths": paths}
    d = known.get(addr)
    if d and d["action"] == k and set(paths) <= set(d["attributes"]):
        out["emulator"].append(addr)
        emulator_parents.add(addr)
cascades = {c: p for p, d in known.items() if p in emulator_parents for c in d.get("cascade", [])}
for addr, k, ch in changes:
    if addr in out["emulator"]:
        continue
    if addr in cascades and set(out["details"][addr]["paths"]) <= PARENT_REFS:
        out["cascade"].append(addr)
    else:
        out["real"].append(addr)
json.dump(out, sys.stdout, indent=1)
