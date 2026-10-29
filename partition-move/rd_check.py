#!/usr/bin/env python3

#######################################################
# rd_check.py
#######################################################
#
# Author:
#   Eng. Abdulmonem Alaa Aldeen
#
# Purpose:
#   Routing view of the route domains for a set of addresses
#   (read-only). Answers "will the servers still be reachable
#   after the move to another route domain?":
#     - Per route domain: VLANs, self IPs (connected subnets),
#       static routes and their gateways
#     - Per address: which route domain(s) already use it
#       (nodes, virtual addresses, SNAT translations), and how the
#       target route domain would reach it: connected subnet,
#       longest static route, default route, or not at all
#
# Requirements:
#   Same folder as f5_partition_move.py (it uses its parser).
#   System python3 on the BIG-IP, standard library only. IPv4.
#
# Usage:
#   python3 rd_check.py --ip 192.0.2.21 --ip 192.0.2.22            # target RD 0
#   python3 rd_check.py --rd 20 --ip 192.0.2.21 --scf saved.scf
#
#######################################################

"""rd_check.py - routing view of the route domains for a set of addresses (read-only)."""
import argparse
import ipaddress
import re

import f5_partition_move as pm

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument("--ip", action="append", default=[], required=True, help="server or VIP address (repeatable)")
ap.add_argument("--rd", type=int, default=0, help="target route domain to check reachability in (default 0)")
ap.add_argument("--scf", help="use an existing single-file config instead of a fresh snapshot")
a = ap.parse_args()
target = a.rd
text = open(a.scf, encoding="utf-8", errors="replace").read() if a.scf else pm.take_snapshot()
cfg = pm.Config(pm.parse_config(text))
rd_by_id = {}
for o in cfg.objs:
    if o["kind"] == "net route-domain":
        m = re.search(r"^\s+id (\d+)", o["body"], re.M)
        rd_by_id[int(m.group(1)) if m else 0] = o


def split(raw, part):
    m = re.match(r"(\d{1,3}(?:\.\d{1,3}){3})(?:%(\d+))?(?:/(\d+))?$", raw)
    if not m:
        return None
    return m.group(1), int(m.group(2)) if m.group(2) else cfg.partitions.get(part, 0), m.group(3)


selfs, routes = [], []
for o in cfg.objs:
    if o["kind"] == "net self":
        s = split(re.search(r"address (\S+)", o["body"]).group(1), o["part"])
        if not s:
            continue
        vlan = re.search(r"^\s+vlan (\S+)", o["body"], re.M)
        tg = re.search(r"traffic-group (\S+)", o["body"])
        selfs.append((s[1], ipaddress.ip_network("%s/%s" % (s[0], s[2] or 32), strict=False), s[0], o["name"], vlan.group(1) if vlan else "-", tg.group(1).split("/")[-1] if tg else ""))
    if o["kind"] == "net route":
        net = re.search(r"^\s+network (\S+)", o["body"], re.M)
        gw = re.search(r"^\s+(gw|interface|pool|tm-route-type) (\S+)", o["body"], re.M)
        raw = net.group(1) if net else "?"
        if raw.startswith("default-inet6"):
            continue
        if raw.startswith("default"):
            rd = int(raw.split("%")[1]) if "%" in raw else cfg.partitions.get(o["part"], 0)
            netobj = ipaddress.ip_network("0.0.0.0/0")
        else:
            s = split(raw, o["part"])
            if not s:
                continue
            rd = s[1]
            netobj = ipaddress.ip_network("%s/%s" % (s[0], s[2] or 32), strict=False)
        routes.append((rd, netobj, o["name"], "%s %s" % gw.groups() if gw else "-"))

for rd in sorted({target} | set(rd_by_id)):
    o = rd_by_id.get(rd)
    vl = re.search(r"vlans \{(.*?)\}", o["body"], re.S) if o else None
    vlans = [v.split("/")[-1] for v in vl.group(1).split()] if vl else []
    strict = "strict disabled" not in (o["body"] if o else "")
    parent = re.search(r"parent (\S+)", o["body"]).group(1) if o and "parent" in o["body"] else "-"
    print("=" * 100)
    print("ROUTE DOMAIN %d  (%s)  strict=%s parent=%s  vlans=%d" % (rd, o["name"] if o else "?", strict, parent, len(vlans)))
    print("  VLANs:", ", ".join(vlans))
    print("  self IPs / connected subnets:")
    for r, net, ip, name, vlan, tg in sorted(selfs, key=lambda x: str(x[1])):
        if r == rd:
            print("     %-20s %-16s %-40s vlan=%-28s %s" % (net, ip, name, vlan.split("/")[-1], tg))
    print("  static routes:")
    for r, net, name, via in routes:
        if r == rd:
            print("     %-20s via %-35s %s" % (net, via, name))

print("=" * 100)
print("ADDRESS CHECK (who already uses each address, and how route domain %d would reach it)" % target)
users = []
for o in cfg.objs:
    if o["kind"] in ("ltm node", "ltm virtual-address", "ltm snat-translation"):
        m = re.search(r"^\s+address (\S+)", o["body"], re.M)
        raw = m.group(1) if m else o["name"].split("/")[-1]
        s = split(raw, o["part"])
        if s:
            users.append((s[0], s[1], o["kind"], o["name"]))
for ip in a.ip:
    addr = ipaddress.ip_address(ip)
    print("-" * 100)
    print(ip)
    for uip, urd, kind, name in users:
        if uip == ip:
            print("   used in RD %-3d by %s %s" % (urd, kind, name))
    for r, net, sip, name, vlan, tg in selfs:
        if addr in net:
            print("   inside connected subnet %s of RD %d (self %s on %s)" % (net, r, sip, vlan.split("/")[-1]))
    best = None
    for r, net, name, via in routes:
        if r == target and addr in net and (best is None or net.prefixlen > best[0].prefixlen):
            best = (net, via, name)
    conn = [net for r, net, *_ in selfs if r == target and addr in net]
    print("   in RD %d: %s" % (target, "connected (%s)" % conn[0] if conn else
                                ("static route %s via %s (%s)" % best if best else "NO route - not reachable in RD %d" % target)))
