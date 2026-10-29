#!/usr/bin/env python3

#######################################################
# f5_partition_move.py
#######################################################
#
# Author:
#   Eng. Abdulmonem Alaa Aldeen
#
# Purpose:
#   Move LTM applications (virtual servers and everything they
#   depend on) from one administrative partition to another,
#   optionally into a different route domain.
#
#   discover (read-only):
#     - Walks every object the virtual servers use: pools, nodes,
#       monitors, profiles, persistence, iRules, data-groups,
#       policies, SNAT pools, virtual addresses, certificates
#     - Checks who else uses each object and whether an object with
#       the same name already exists in the destination
#     - Prints a tree plus a summary: MOVE / SHARED / CONFLICT-SAME /
#       CONFLICT-DIFF / BLOCKER / COMMON
#
#   generate (writes files only, changes nothing on the box):
#     - One job folder with numbered scripts: precheck (+ UCS),
#       create, optional route, verify, delete source, rollback
#
# Requirements:
#   Runs on the BIG-IP itself with the system python3
#   (standard library only). Reads the running config from a
#   temporary single-file snapshot that is deleted afterwards.
#
# Usage:
#   python3 f5_partition_move.py discover --src Legacy --vs app1_vip_443
#   python3 f5_partition_move.py generate --src Legacy --dst Common \
#       --vs app1_vip_443 --vs app1_vip_80 --vlans all --out jobs/app1
#
#######################################################

"""f5_partition_move.py - move BIG-IP LTM applications between partitions.

Phase 1 - discover (read-only): starting from one or more virtual servers, walk everything they depend on,
check who else uses each object, and report what can move, what is shared, and what blocks the move.

    python3 f5_partition_move.py discover --src Legacy --vs app1_vip_443 --vs app1_vip_80
    python3 f5_partition_move.py discover --src Legacy --vs-file vs_list.txt --json app1_discovery.json
    python3 f5_partition_move.py discover --src Legacy --all             # every virtual in the partition (planning)
    python3 f5_partition_move.py discover --src Legacy --scf saved.scf ... # reuse a snapshot instead of a new one

Phase 2 - generate: the same discovery, then a job folder with the change files (nothing is applied).

    python3 f5_partition_move.py generate --src Legacy --dst Common --vs app1_vip_443 --vlans all --out jobs/app1

The running configuration is read from a temporary single-file snapshot (tmsh save sys config file ...),
which does not change /config. The snapshot and its .tar (it contains certificate/key copies) are deleted.
Runs on the BIG-IP itself with the system python3; standard library only.
"""
import argparse
import collections
import json
import os
import re
import subprocess
import sys
import time

# ----------------------------------------------------------------------------- config parsing
# bodies are Tcl: count braces only (quotes do not protect braces), as tmsh does
SCRIPT_KINDS = ("ltm rule", "gtm rule", "sys icall script", "pem irule", "cli script", "sys application template",
                "sys application apl-script")


def take_snapshot():
    path = "/var/tmp/f5pm_%d.scf" % int(time.time())
    try:
        subprocess.run(["tmsh", "save", "sys", "config", "file", path, "no-passphrase"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    finally:
        for p in (path, path + ".tar"):
            if os.path.exists(p):
                os.remove(p)


def split_header(header):
    """'ltm virtual /P/name' -> ('ltm virtual', '/P/name'); handles quoted names."""
    tokens = re.findall(r'"[^"]*"|\S+', header)
    tokens = [t[1:-1] if t.startswith('"') else t for t in tokens]
    if len(tokens) >= 2 and tokens[-1].startswith("/"):
        return " ".join(tokens[:-1]), tokens[-1]
    # objects named without a path: 'auth partition Legacy', 'net route-domain 0', 'sys global-settings'
    for n in (2, 1):
        if len(tokens) > n:
            return " ".join(tokens[:n]), " ".join(tokens[n:])
    return " ".join(tokens), ""


def parse_config(text):
    """Return a list of dicts {kind, name, body} for every top-level object."""
    objs, lines, i = [], text.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        if not line or line[0] in " \t#}" or not line.rstrip().endswith("{") and "{" not in line:
            i += 1
            continue
        header = line[:line.index("{")].strip()
        kind, name = split_header(header)
        script = kind in SCRIPT_KINDS
        depth, body = 0, []
        j = i
        while j < len(lines):
            depth += brace_delta(lines[j], script, first=(j == i))
            body.append(lines[j])
            if depth <= 0:
                break
            j += 1
        objs.append({"kind": kind, "name": name, "body": "\n".join(body[1:-1]) if len(body) > 1 else ""})
        i = j + 1
    return objs


def brace_delta(line, script, first=False):
    d, in_q, esc = 0, False, False
    for ch in line:
        if esc:
            esc = False
            continue
        if ch == "\\":
            esc = True
            continue
        if not script and ch == '"':
            in_q = not in_q
            continue
        if in_q:
            continue
        if ch == "{":
            d += 1
        elif ch == "}":
            d -= 1
    return d


# ----------------------------------------------------------------------------- reference extraction
HINT_KIND = {
    "pool": "ltm pool", "last-hop-pool": "ltm pool", "clone-pools": "ltm pool", "fallback-host": None,
    "monitor": "ltm monitor", "members": "ltm node", "node": "ltm node", "destination": "ltm virtual-address",
    "profiles": "ltm profile", "persist": "ltm persistence", "fallback-persistence": "ltm persistence",
    "rules": "ltm rule", "policies": "ltm policy", "vlans": "net vlan", "virtual": "ltm virtual",
    "cert": "sys file ssl-cert", "chain": "sys file ssl-cert", "ca-file": "sys file ssl-cert",
    "client-cert-ca": "sys file ssl-cert", "key": "sys file ssl-key", "crl-file": "sys file ssl-crl",
    "snatpool": "ltm snatpool", "snat-pool": "ltm snatpool", "route-domain": "net route-domain",
}
NO_DESCEND = {"net vlan", "net self", "net route-domain", "auth partition", "net route", "net tunnels tunnel"}


class Config:
    def __init__(self, objs):
        self.objs = objs
        self.by_name = collections.defaultdict(list)
        for o in objs:
            o["part"] = o["name"].split("/")[1] if o["name"].startswith("/") and o["name"].count("/") >= 2 else None
            o["id"] = "%s %s" % (o["kind"], o["name"])
            self.by_name[o["name"]].append(o)
        self.by_id = {o["id"]: o for o in objs}
        self.partitions = {"Common": 0}
        for o in objs:
            if o["kind"] == "auth partition":
                m = re.search(r"default-route-domain (\d+)", o["body"])
                self.partitions[o["name"]] = int(m.group(1)) if m else 0
        self.short = collections.defaultdict(list)          # (partition, short name) -> objects
        for o in objs:
            if o["part"]:
                self.short[(o["part"], o["name"].split("/", 2)[2])].append(o)
        for o in objs:
            o["refs"] = self._refs(o)
        self.rev = collections.defaultdict(set)
        for o in objs:
            for r, how in o["refs"]:
                self.rev[r].add((o["id"], how))

    def _resolve(self, token, hint, owner):
        cands = []
        for t in (token, token.rsplit(":", 1)[0] if ":" in token else None, token.rsplit(".", 1)[0] if "." in token else None):
            if t and t in self.by_name:
                cands = self.by_name[t]
                break
        if token.startswith("/Common/") and hint and hint != "same-family" and not any(c["kind"].startswith(hint) for c in cands):
            # built-in system objects (tcp, http, clientssl, gateway_icmp ...) are not in the saved config;
            # one name can be a built-in of several kinds (/Common/tcp is a profile and a monitor)
            kind = hint + " (built-in)"
            oid = "%s %s" % (kind, token)
            if oid not in self.by_id:
                pseudo = {"kind": kind, "name": token, "body": "", "part": "Common", "id": oid, "refs": set()}
                self.by_id[oid] = pseudo
                self.by_name[token].append(pseudo)
            return [self.by_id[oid]]
        if not cands:
            return []
        if hint == "same-family":
            fam = " ".join(owner["kind"].split()[:2])
            picked = [c for c in cands if c["kind"].startswith(fam)]
        elif hint:
            picked = [c for c in cands if c["kind"].startswith(hint)]
        else:
            picked = []
        return picked or cands

    def _refs(self, o):
        out = set()
        if o["kind"] in SCRIPT_KINDS:
            out |= self._irule_refs(o)
            return out
        stack = []
        for raw in o["body"].split("\n"):
            line = raw.strip()
            if line == "}":
                if stack:
                    stack.pop()
                continue
            words = line.split()
            if not words:
                continue
            first = words[0]
            for m in re.finditer(r'(?<![\w/])(/[\w.\-]+/[^\s{}"]+)', line):
                token = m.group(1)
                before = line[:m.start()].split()
                prev = before[-1] if before else (stack[-1] if stack else "")
                if prev == "pool" and "source-address-translation" in stack:
                    hint = "ltm snatpool"
                elif o["kind"] == "ltm snatpool" and (stack[-1:] == ["members"] or prev == "members"):
                    hint = "ltm snat-translation"
                elif prev == "defaults-from" or first == "defaults-from":
                    hint = "same-family"
                else:
                    hint = HINT_KIND.get(prev) or HINT_KIND.get(first) or (HINT_KIND.get(stack[-1]) if stack else None)
                for c in self._resolve(token, hint, o):
                    if c["id"] != o["id"]:
                        out.add((c["id"], prev or first))
            if line.endswith("{"):
                stack.append(first if not first.startswith("/") else (stack[-1] if stack else first))
        return out

    def _irule_refs(self, o):
        """Names of pools / data-groups / snatpools / virtuals / nodes mentioned in iRule text (same partition or Common)."""
        out = set()
        words = set(re.findall(r"[\w.\-/%:]+", o["body"]))
        for w in words:
            for part, nm in ((o["part"], w), ("Common", w)):
                if w.startswith("/"):
                    objs = self.by_name.get(w, [])
                else:
                    objs = self.short.get((part, nm), [])
                for c in objs:
                    if c["kind"] in ("ltm pool", "ltm snatpool", "ltm virtual", "ltm node") or c["kind"].startswith("ltm data-group") \
                            or c["kind"].startswith("sys file"):
                        out.add((c["id"], "irule-text"))
        return out


# ----------------------------------------------------------------------------- discovery
IPV4 = re.compile(r"(?<![\w.%])(\d{1,3}(?:\.\d{1,3}){3})(%\d+)?(?![\w%])")
# objects whose addresses live in a route domain (monitor destinations, iRule and data-group text do not)
RD_KINDS = ("ltm node", "ltm pool", "ltm virtual", "ltm virtual-address", "ltm snatpool", "ltm snat-translation", "ltm snat")


def normalized(body, part, dst, cfg, kind=""):
    """Body as it would read in the destination: partition paths rewritten, addresses with their route domain."""
    rd = cfg.partitions.get(part, 0)
    b = body.replace("/%s/" % part, "/%s/" % dst)
    b = re.sub(r"\$M\$\S+", "$M$<secret>", b)            # encrypted values use a random IV: never equal as text
    b = b.replace("destination *.*", "destination *:*")    # two spellings of the same wildcard
    if kind in RD_KINDS:
        b = IPV4.sub(lambda m: "%s%s" % (m.group(1), m.group(2) or "%%%d" % rd), b)
    return [l.strip() for l in b.split("\n") if l.strip() and not l.strip().startswith(("description", "partition"))]


def discover(cfg, vs_names, src, dst, pools=()):
    start, missing = [], []
    for kind, names in (("ltm virtual", vs_names), ("ltm pool", pools)):
        for n in names:
            full = n if n.startswith("/") else "/%s/%s" % (src, n)
            o = cfg.by_id.get("%s %s" % (kind, full))
            (start if o else missing).append(o or full)

    tree, seen, order = collections.defaultdict(list), set(), []
    queue = collections.deque((o["id"], None, "start") for o in start)
    while queue:
        oid, parent, how = queue.popleft()
        if parent:
            tree[parent].append((oid, how))
        if oid in seen:
            continue
        seen.add(oid)
        order.append(oid)
        o = cfg.by_id[oid]
        if o["part"] != src or o["kind"] in NO_DESCEND:
            continue                                   # Common objects stay; network objects are reported, not walked
        for r, h in sorted(o["refs"]):
            queue.append((r, oid, h))

    moving = {oid for oid in seen if cfg.by_id[oid]["part"] == src and cfg.by_id[oid]["kind"] not in NO_DESCEND}
    result = {}
    for oid in order:
        o = cfg.by_id[oid]
        short = o["name"].split("/", 2)[2] if o["part"] else o["name"]
        entry = {"kind": o["kind"], "name": o["name"], "partition": o["part"], "status": None, "notes": []}
        if o["part"] == "Common":
            entry["status"] = "COMMON"
        elif o["part"] != src:
            entry["status"] = "BLOCKER"
            entry["notes"].append("object in partition %s; %s cannot reference it" % (o["part"], dst))
        elif o["kind"] in NO_DESCEND:
            users = sorted(u for u, _ in cfg.rev.get(oid, ()) if cfg.by_id[u]["kind"] == "ltm virtual")
            entry["status"] = "BLOCKER"
            role = " - the virtual server LISTENS on it (client side)" if o["kind"] == "net vlan" else ""
            entry["notes"].append("%s in partition %s%s; a %s object cannot reference it (listed by %d virtual servers)"
                                  % (o["kind"], src, role, dst, len(users)))
        else:
            others = sorted({u for u, how in cfg.rev.get(oid, ()) if u not in moving})
            entry["status"] = "SHARED" if others else "MOVE"
            if others:
                entry["notes"].append("also used by: " + ", ".join(others[:12]) + (" ..." if len(others) > 12 else ""))
                entry["shared_with"] = others
            if any(u for u, how in cfg.rev.get(oid, ()) if how == "irule-text"):
                entry["notes"].append("referenced inside iRule text: review the iRule after the move")
            twin = [c for c in cfg.short.get((dst, short), []) if c["kind"] == o["kind"]]
            if twin:
                same = normalized(o["body"], src, dst, cfg, o["kind"]) == normalized(twin[0]["body"], dst, dst, cfg, o["kind"])
                entry["status"] = "CONFLICT-SAME" if same else "CONFLICT-DIFF"
                entry["notes"].append("/%s/%s already exists in the destination (%s, route domains considered)"
                                      % (dst, short, "identical: reuse it and re-point" if same else "DIFFERENT configuration"))
                if "$M$" in o["body"]:
                    entry["notes"].append("contains encrypted fields (passwords/secrets): verify they match before reusing")
            if o["kind"] in ("ltm node", "ltm virtual-address", "ltm snat-translation") or o["kind"] == "ltm pool":
                addrs = re.findall(r"^\s*address (\S+)", o["body"], re.M)
                if o["kind"] == "ltm virtual-address":
                    addrs = addrs or [short]
                bare = [a for a in addrs if "%" not in a and a != "any"]
                if bare and cfg.partitions.get(src, 0) != cfg.partitions.get(dst, 0):
                    rd = cfg.partitions.get(src, 0)
                    entry["notes"].append("address(es) %s are in route domain %d (partition default); to stay there in %s they need %%%d"
                                          " (generate --target-rd %d)" % (", ".join(sorted(set(bare))), rd, dst, rd, rd))
            if o["kind"] == "sys file ssl-key" and re.search(r"security-type (fips|nethsm|password)", o["body"]):
                entry["notes"].append("key is %s - cannot be copied as a normal file" % re.search(r"security-type (\S+)", o["body"]).group(1))
            if o["kind"].startswith("sys file"):
                m = re.search(r"cache-path (\S+)", o["body"])
                if m:
                    entry["file"] = m.group(1)
        result[oid] = entry
    return {"start": [o["id"] for o in start], "missing": missing, "tree": tree, "objects": result,
            "route_domains": {src: cfg.partitions.get(src), dst: cfg.partitions.get(dst)}}


# ----------------------------------------------------------------------------- report
def report(cfg, d, src, dst):
    out = []
    p = out.append
    p("=" * 100)
    p("partition-move discovery  %s -> %s   (%s)" % (src, dst, time.strftime("%Y-%m-%d %H:%M:%S")))
    p("route domains: %s default RD %s | %s default RD %s" % (src, d["route_domains"][src], dst, d["route_domains"][dst]))
    if d["missing"]:
        p("NOT FOUND: " + ", ".join(d["missing"]))
    objs = d["objects"]

    def walk(oid, depth, path):
        e = objs[oid]
        p("%s%-9s %s %s%s" % ("    " * depth, e["status"], e["kind"], e["name"], "" if not e["notes"] else "   <- " + "; ".join(e["notes"])[:220]))
        if oid in path:
            return
        kids = sorted({k for k, _ in d["tree"].get(oid, [])})
        for k in kids:
            walk(k, depth + 1, path | {oid})

    for s in d["start"]:
        p("-" * 100)
        walk(s, 0, frozenset())
    p("-" * 100)
    by = collections.defaultdict(list)
    for e in objs.values():
        by[e["status"]].append(e)
    p("SUMMARY")
    for st in ("MOVE", "SHARED", "CONFLICT-SAME", "CONFLICT-DIFF", "BLOCKER", "COMMON"):
        items = by.get(st, [])
        kinds = collections.Counter(e["kind"] for e in items)
        p("  %-13s %3d  %s" % (st, len(items), ", ".join("%s=%d" % kv for kv in sorted(kinds.items()))))
    for st, title in (("SHARED", "SHARED objects (decide: move and re-point the other users, or keep a copy)"),
                      ("BLOCKER", "BLOCKERS (must be solved before the move)"),
                      ("CONFLICT-DIFF", "CONFLICTS - same name in destination, DIFFERENT configuration (decide per object)"),
                      ("CONFLICT-SAME", "CONFLICTS - same name in destination, identical configuration (reuse, re-point)")):
        if by.get(st):
            p("")
            p(title + ":")
            for e in by[st]:
                p("  - %s %s" % (e["kind"], e["name"]))
                for n in e["notes"]:
                    p("        " + n)
    certs = [e for e in objs.values() if e["kind"].startswith("sys file") and e["partition"] == src]
    if certs:
        p("")
        p("CERTIFICATES / KEYS to copy (with their files):")
        for e in certs:
            p("  - %s %s  file=%s" % (e["kind"], e["name"], e.get("file", "?")))
    return "\n".join(out)


# ----------------------------------------------------------------------------- generate
# creation order; deletion uses the reverse
ORDER = ("sys file ssl-key", "sys file ssl-cert", "ltm monitor", "ltm profile", "ltm persistence", "ltm rule",
         "ltm data-group", "ltm snat-translation", "ltm snatpool", "ltm node", "ltm pool", "ltm virtual-address",
         "ltm policy", "ltm virtual")


# looks the object up in its folder listing: a missing object must not write an error line to /var/log/ltm
EXISTS_SH = 'exists() { tmsh -q -c "cd ${2%/*}; list $1 one-line" 2>/dev/null | grep -qF "$1 ${2##*/} {"; }'


def rank(kind):
    for i, k in enumerate(ORDER):
        if kind.startswith(k):
            return i
    return len(ORDER)


def retarget(text, cfg, src, dst, target_rd, kind):
    """Rewrite an object (header + body) from the source partition / route domain to the destination."""
    src_rd, dst_rd = cfg.partitions.get(src, 0), cfg.partitions.get(dst, 0)
    t = text.replace("/%s/" % src, "/%s/" % dst)
    # explicit suffixes (virtual-address names, destinations): %11 -> nothing (destination default) or %<target>
    t = re.sub(r"%%%d(?!\d)" % src_rd, "" if target_rd == dst_rd else "%%%d" % target_rd, t)
    if target_rd != dst_rd and kind in RD_KINDS:
        # bare addresses were relative to the source partition; make the target route domain explicit:
        # address lines, IP-named objects and members (/Common/192.0.2.1:80), virtual destination and source
        sfx = "%%%d" % target_rd
        t = re.sub(r"^(\s+address )(\d{1,3}(?:\.\d{1,3}){3})$", r"\g<1>\g<2>" + sfx, t, flags=re.M)
        t = re.sub(r"(/%s/\d{1,3}(?:\.\d{1,3}){3})(?![\d.%%])" % re.escape(dst), r"\g<1>" + sfx, t)
        t = re.sub(r"^(\s+source )(\d{1,3}(?:\.\d{1,3}){3})(/\d+)$", r"\g<1>\g<2>" + sfx + r"\g<3>", t, flags=re.M)
    return t


def vlans_all(body):
    """Listen on every VLAN of the route domain (the default tmsh does not print)."""
    body = re.sub(r"\n    vlans \{.*?\n    \}", "", "\n" + body, flags=re.S)
    body = re.sub(r"\n    vlans-(enabled|disabled)(?=\n|$)", "", body)
    return (body + "\n    vlans-disabled").lstrip("\n")


def generate(cfg, d, src, dst, target_rd, vlans, routes, out, job, report_text):
    objs = d["objects"]
    stop = []
    for e in objs.values():
        if e["status"] == "SHARED":
            stop.append("SHARED %s %s: %s" % (e["kind"], e["name"], "; ".join(e["notes"])))
        if e["status"] == "CONFLICT-DIFF":
            stop.append("CONFLICT-DIFF %s %s" % (e["kind"], e["name"]))
        if e["status"] == "BLOCKER" and not (e["kind"] == "net vlan" and vlans == "all"):
            hint = " (or use --vlans all: listen on every VLAN of the target route domain)" if e["kind"] == "net vlan" else ""
            stop.append("BLOCKER %s %s%s" % (e["kind"], e["name"], hint))
        if e["status"] in ("MOVE",) and e["kind"].startswith("sys file"):
            stop.append("certificate/key copy is not automated yet: %s %s" % (e["kind"], e["name"]))
    if stop:
        sys.exit("generate stopped - solve these first:\n  " + "\n  ".join(stop))

    move = sorted((cfg.by_id[oid] for oid, e in objs.items() if e["status"] == "MOVE"), key=lambda o: (rank(o["kind"]), o["name"]))
    reuse = [e for e in objs.values() if e["status"] == "CONFLICT-SAME"]
    new_names = []
    create, rollback = [], []
    for o in move:
        body = o["body"]
        if o["kind"] == "ltm virtual" and vlans == "all":
            body = vlans_all(body)
        original = "%s %s {\n%s\n}" % (o["kind"], o["name"], o["body"])
        rollback.append(original)
        new = retarget("%s %s {\n%s\n}" % (o["kind"], o["name"], body), cfg, src, dst, target_rd, o["kind"])
        create.append(new)
        new_names.append((o["kind"], new.split("\n", 1)[0][len(o["kind"]) + 1:-2]))

    # names that must not exist yet in the destination (address uniqueness is per route domain)
    os.makedirs(out, exist_ok=True)

    def w(name, text, mode=0o644):
        p = os.path.join(out, name)
        with open(p, "w", newline="\n") as f:          # LF even when generated off-box
            f.write(text)
        os.chmod(p, mode)

    hdr = "#!/bin/bash\n# partition-move job %s: %s -> %s, route domain %d, vlans=%s\n# generated %s - review before running\n" % (
        job, src, dst, target_rd, vlans, time.strftime("%Y-%m-%d %H:%M:%S"))
    # same route domain as the source: an address cannot exist twice, so the originals must go before the new ones
    same_rd = target_rd == cfg.partitions.get(src, 0)
    first = "# same route domain as /%s: run 30_delete_%s.sh BEFORE this script, in the maintenance window\n" % (src, src) if same_rd else ""
    w("00_discovery.txt", report_text + "\n")
    w("10_create_%s.conf" % dst, "# objects to create in /%s (route domain %d). Load with 11_create.sh\n" % (dst, target_rd) + "\n".join(create) + "\n")
    w("90_rollback_%s.conf" % src, "# original /%s objects, unchanged. Loaded by 91_rollback.sh\n" % src + "\n".join(rollback) + "\n")

    chk = "\n".join('chk "%s" "%s"' % (o["kind"], o["name"]) for o in move)
    new_chk = "\n".join('absent "%s" "%s"' % kn for kn in new_names)
    w("01_precheck.sh", hdr + """set -u
%s
chk()    { exists "$1" "$2" && echo "OK      source exists: $1 $2" || { echo "MISSING source: $1 $2"; BAD=1; }; }
absent() { exists "$1" "$2" && { echo "EXISTS  target already there: $1 $2"; BAD=1; } || echo "OK      target free: $1 $2"; }
BAD=0""" % EXISTS_SH + """
%s
%s
echo "reused from /%s (identical, not created): %s"
tmsh save sys ucs /var/local/ucs/pre_%s.ucs | tail -1
[ $BAD -eq 0 ] && echo "PRECHECK OK" || { echo "PRECHECK FAILED"; exit 1; }
""" % (chk, new_chk, dst, ", ".join(e["name"] for e in reuse) or "none", job), 0o755)

    w("11_create.sh", hdr + first + """set -e
cd "$(dirname "$0")"
tmsh load sys config merge file $PWD/10_create_%s.conf verify
tmsh load sys config merge file $PWD/10_create_%s.conf
tmsh save sys config | tail -1
echo "CREATED - now run 20_verify.sh; sync the device group when satisfied"
""" % (dst, dst), 0o755)

    if routes:
        rt = []
        for r in routes:
            name, net, gw = r.split(",")
            suffix = "" if target_rd == cfg.partitions.get(dst, 0) else "%%%d" % target_rd
            ip, slash, plen = net.partition("/")            # the route domain goes before the prefix: 192.0.2.0%11/24
            rt.append("net route /%s/%s {\n    gw %s%s\n    network %s%s%s%s\n}" % (dst, name, gw, suffix, ip, suffix, slash, plen))
        w("12_route_%s.conf" % dst, "# route(s) the moved servers need in route domain %d\n" % target_rd + "\n".join(rt) + "\n")
        w("12_add_route.sh", hdr + """set -e
cd "$(dirname "$0")"
tmsh load sys config merge file $PWD/12_route_%s.conf verify
tmsh load sys config merge file $PWD/12_route_%s.conf
tmsh save sys config | tail -1
""" % (dst, dst), 0o755)
        w("92_remove_route.sh", hdr + "# removes the route(s) added by 12_add_route.sh\n" +
          "\n".join("tmsh delete net route /%s/%s && echo 'deleted route %s'" % (dst, r.split(",")[0], r.split(",")[0]) for r in routes) +
          "\ntmsh save sys config | tail -1\n", 0o755)

    vs_new = [n for k, n in new_names if k == "ltm virtual"]
    pool_new = [n for k, n in new_names if k == "ltm pool"]
    w("20_verify.sh", hdr + """
for v in %s; do echo "== $v"; tmsh list ltm virtual $v destination pool vlans vlans-disabled vlans-enabled | grep -vE '^}'; tmsh show ltm virtual $v | grep -E 'Availability|Reason'; done
for p in %s; do echo "== $p"; tmsh show ltm pool $p members | grep -E 'Pool Member|Availability|Reason'; done
""" % (" ".join(vs_new), " ".join(pool_new)), 0o755)

    dels = [(o["kind"], o["name"]) for o in sorted(move, key=lambda o: -rank(o["kind"]))]
    when = ("same route domain as the new ones: run this BEFORE 11_create.sh (91_rollback.sh restores them)" if same_rd
            else "run only after the new ones are verified")
    w("30_delete_%s.sh" % src, hdr + """# removes the ORIGINAL objects from /%s - %s
set -u
%s
del() { if exists "$1" "$2"; then tmsh delete $1 $2 && echo "deleted $1 $2" || { echo "FAILED  $1 $2"; FAIL=1; }; else echo "gone    $1 $2"; fi; }
FAIL=0
%s
tmsh save sys config | tail -1
[ $FAIL -eq 0 ] && echo "SOURCE REMOVED" || { echo "SOME DELETES FAILED - check above"; exit 1; }
""" % (src, when, EXISTS_SH, "\n".join('del "%s" "%s"' % kn for kn in dels)), 0o755)

    rdel = [(k, n) for k, n in sorted(new_names, key=lambda kn: -rank(kn[0]))]
    w("91_rollback.sh", hdr + """# puts the application back in /%s: removes the new /%s objects, then restores the originals
set -u
cd "$(dirname "$0")"
%s
del() { if exists "$1" "$2"; then tmsh delete $1 $2 && echo "deleted $1 $2"; else echo "gone    $1 $2"; fi; }
%s
tmsh load sys config merge file $PWD/90_rollback_%s.conf verify && tmsh load sys config merge file $PWD/90_rollback_%s.conf
tmsh save sys config | tail -1
echo "ROLLBACK DONE"
""" % (src, dst, EXISTS_SH, "\n".join('del "%s" "%s"' % kn for kn in rdel), src, src), 0o755)
    return move, reuse, new_names


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    gp = sub.add_parser("generate", help="write the change files for a move (nothing is changed on the box)")
    gp.add_argument("--vs", action="append", default=[], help="virtual server name (repeatable)")
    gp.add_argument("--vs-file", help="file with one virtual server name per line")
    gp.add_argument("--pool", action="append", default=[], help="extra pool that no virtual server uses")
    gp.add_argument("--src", required=True, help="source partition")
    gp.add_argument("--dst", default="Common", help="destination partition (default Common)")
    gp.add_argument("--target-rd", type=int, help="route domain of the moved objects (default: the destination partition's)")
    gp.add_argument("--vlans", choices=("keep", "all"), default="keep",
                    help="keep = same VLAN list (default); all = listen on every VLAN of the target route domain")
    gp.add_argument("--route", action="append", default=[], help="NAME,NETWORK,GATEWAY route to add in the target RD")
    gp.add_argument("--out", required=True, help="output folder for the job files")
    gp.add_argument("--scf", help="use an existing single-file config instead of a fresh snapshot")
    dp = sub.add_parser("discover", help="read-only report of what a move involves")
    dp.add_argument("--vs", action="append", default=[], help="virtual server name (repeatable)")
    dp.add_argument("--pool", action="append", default=[], help="extra pool that no virtual server uses")
    dp.add_argument("--vs-file", help="file with one virtual server name per line")
    dp.add_argument("--all", action="store_true", help="every virtual server in the source partition")
    dp.add_argument("--src", required=True, help="source partition")
    dp.add_argument("--dst", default="Common", help="destination partition (default Common)")
    dp.add_argument("--scf", help="use an existing single-file config instead of a fresh snapshot")
    dp.add_argument("--json", help="also write the result as JSON")
    a = ap.parse_args()
    if a.cmd not in ("discover", "generate"):
        ap.print_help()
        return 1
    text = open(a.scf, encoding="utf-8", errors="replace").read() if a.scf else take_snapshot()
    cfg = Config(parse_config(text))
    names = list(a.vs)
    if getattr(a, "vs_file", None):
        names += [l.strip() for l in open(a.vs_file) if l.strip() and not l.startswith("#")]
    if getattr(a, "all", False):
        names += [o["name"] for o in cfg.objs if o["kind"] == "ltm virtual" and o["part"] == a.src]
    pools = getattr(a, "pool", [])
    if not names and not pools:
        sys.exit("give --vs, --vs-file, --pool or --all")
    if a.src not in cfg.partitions or a.dst not in cfg.partitions:
        sys.exit("unknown partition; known: %s" % ", ".join(sorted(cfg.partitions)))
    d = discover(cfg, names, a.src, a.dst, pools)
    if d["missing"]:
        sys.exit("not found: " + ", ".join(d["missing"]))
    text_report = report(cfg, d, a.src, a.dst)
    if a.cmd == "generate":
        job = os.path.basename(os.path.normpath(a.out))
        target_rd = a.target_rd if a.target_rd is not None else cfg.partitions[a.dst]
        move, reuse, new = generate(cfg, d, a.src, a.dst, target_rd, a.vlans, a.route, a.out, job, text_report)
        print(text_report)
        print("\nGENERATED in %s: %d objects to create in /%s (route domain %d), %d reused from /%s, vlans=%s"
              % (a.out, len(move), a.dst, target_rd, len(reuse), a.dst, a.vlans))
        for f in sorted(os.listdir(a.out)):
            print("   " + f)
        if target_rd == cfg.partitions[a.src]:
            print("\nNOTE: route domain %d is the source's own - old and new objects cannot exist together (same addresses).\n"
                  "      Order: 01_precheck -> 30_delete_%s -> 11_create -> 20_verify, in one maintenance window;"
                  " rollback: 91_rollback" % (target_rd, a.src))
        return 0
    print(text_report)
    if a.json:
        d2 = dict(d, tree={k: v for k, v in d["tree"].items()})
        with open(a.json, "w") as f:
            json.dump(d2, f, indent=1, default=str)
        print("\njson written to " + a.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
