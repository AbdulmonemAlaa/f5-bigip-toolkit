#!/usr/bin/env python3

#######################################################
# vlan_scope.py
#######################################################
#
# Author:
#   Eng. Abdulmonem Alaa Aldeen
#
# Purpose:
#   Everything on the BIG-IP that belongs to one server VLAN
#   (read-only). Useful to scope a partition move by VLAN:
#     - The VLAN: tag, partition, route domain, self IPs, subnets
#     - Nodes whose address is in those subnets (same route domain)
#     - Pools that use those nodes, and the virtual servers using
#       the pools or whose address is inside the subnets
#     - For every virtual server, the VLANs it listens on
#
# Requirements:
#   Same folder as f5_partition_move.py (it uses its parser).
#   System python3 on the BIG-IP, standard library only. IPv4.
#
# Usage:
#   python3 vlan_scope.py app-servers          # VLAN name
#   python3 vlan_scope.py 120                  # or VLAN tag
#   python3 vlan_scope.py 120 --scf saved.scf  # reuse a snapshot
#
#######################################################

"""vlan_scope.py - everything on the BIG-IP that belongs to one server VLAN (read-only)."""
import argparse
import collections
import ipaddress
import re
import sys

import f5_partition_move as pm

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument("vlan", help="VLAN name or tag")
ap.add_argument("--scf", help="use an existing single-file config instead of a fresh snapshot")
a = ap.parse_args()
want = a.vlan
text = open(a.scf, encoding="utf-8", errors="replace").read() if a.scf else pm.take_snapshot()
cfg = pm.Config(pm.parse_config(text))


def rd_of(part):
    return cfg.partitions.get(part, 0)


def addr(o, raw):
    """'192.0.2.1' / '192.0.2.1%11' / '192.0.2.1/24' in object o -> (ip, rd, prefix); None if not IPv4"""
    m = re.match(r"(\d{1,3}(?:\.\d{1,3}){3})(?:%(\d+))?(?:/(\d+))?$", raw)
    if not m:
        return None
    return m.group(1), int(m.group(2)) if m.group(2) else rd_of(o["part"]), int(m.group(3) or 32)


def mentions(body, name):
    return re.search(r"(?<![\w/.\-])%s(?![\w.\-])" % re.escape(name), body)


vlans = [o for o in cfg.objs if o["kind"] == "net vlan" and (o["name"].split("/")[-1] == want or re.search(r"^\s+tag %s$" % re.escape(want), o["body"], re.M))]
if not vlans:
    sys.exit("no VLAN named or tagged %s" % want)
for v in vlans:
    tag = re.search(r"^\s+tag (\d+)", v["body"], re.M)
    print("VLAN %s  tag=%s  partition=%s" % (v["name"], tag.group(1) if tag else "-", v["part"]))
    rds = [o["name"] for o in cfg.objs if o["kind"] == "net route-domain" and mentions(o["body"], v["name"])]
    print("  route domain:", ", ".join(rds) or "-")
    subnets = []
    for s in cfg.objs:
        if s["kind"] == "net self" and re.search(r"^\s+vlan %s$" % re.escape(v["name"]), s["body"], re.M):
            parsed = addr(s, re.search(r"address (\S+)", s["body"]).group(1))
            if not parsed:
                continue
            ip, rd, pfx = parsed
            tg = re.search(r"traffic-group (\S+)", s["body"])
            net = ipaddress.ip_network("%s/%d" % (ip, pfx), strict=False)
            subnets.append((net, rd))
            print("  self IP %-45s %s%%%d  subnet %s  %s" % (s["name"], ip, rd, net, tg.group(1) if tg else ""))
    users = collections.Counter()
    listing = []
    for vs in cfg.objs:
        if vs["kind"] == "ltm virtual" and re.search(r"^\s+%s$" % re.escape(v["name"]), vs["body"], re.M):
            mode = "vlans-enabled" if re.search(r"^\s+vlans-enabled$", vs["body"], re.M) else "vlans-disabled"
            users[mode] += 1
            listing.append((vs, mode))
    print("  virtual servers that list this VLAN: %s" % dict(users))
    if len(listing) <= 15:
        for vs, mode in listing:
            dest = re.search(r"destination (\S+)", vs["body"]).group(1)
            pool = re.search(r"^\s+pool (\S+)", vs["body"], re.M)
            print("     %-40s %-34s pool=%s  (%s)" % (vs["name"], dest, pool.group(1) if pool else "-", mode))

    def in_scope(ip, rd):
        return any(ipaddress.ip_address(ip) in n and rd == r for n, r in subnets)

    nodes = []
    for n in cfg.objs:
        if n["kind"] == "ltm node":
            m = re.search(r"^\s+address (\S+)", n["body"], re.M)
            parsed = addr(n, m.group(1)) if m else None
            if parsed and in_scope(parsed[0], parsed[1]):
                nodes.append(n["name"])
    print("\nNODES in the VLAN subnets (%d): %s" % (len(nodes), ", ".join(nodes)))
    pools = sorted({u for nd in nodes for u, _ in cfg.rev.get("ltm node " + nd, ()) if u.startswith("ltm pool ")})
    print("POOLS using them (%d):" % len(pools))
    vss = set()
    for p in pools:
        refs = sorted(u for u, _ in cfg.rev.get(p, ()) if u.startswith("ltm virtual "))
        vss.update(refs)
        print("   %-55s used by: %s" % (p[9:], ", ".join(r[12:] for r in refs) or "NO virtual server"))
    for vs in cfg.objs:
        if vs["kind"] == "ltm virtual":
            m = re.search(r"destination /[^/]+/(\d{1,3}(?:\.\d{1,3}){3})(?:%(\d+))?", vs["body"])
            if m and in_scope(m.group(1), int(m.group(2)) if m.group(2) else rd_of(vs["part"])):
                vss.add(vs["id"])
    print("\nVIRTUAL SERVERS in scope (%d):" % len(vss))
    for vid in sorted(vss):
        vs = cfg.by_id[vid]
        dest = re.search(r"destination (\S+)", vs["body"]).group(1)
        lst = re.search(r"vlans \{(.*?)\}", vs["body"], re.S)
        # tmsh omits the default (vlans-disabled, empty list = listen on every VLAN of the route domain)
        mode = "enabled" if re.search(r"^\s+vlans-enabled$", vs["body"], re.M) else "disabled"
        names = " ".join(x.split("/")[-1] for x in lst.group(1).split()) if lst else ""
        if mode == "disabled":
            listen = "listens on ALL VLANs" + (" except: " + names if names else "")
        else:
            listen = "listens ONLY on: " + (names or "(none - not reachable)")
        pool = re.search(r"^\s+pool (\S+)", vs["body"], re.M)
        print("   %-35s %-32s pool=%-32s %s" % (vs["name"], dest, pool.group(1).split("/")[-1] if pool else "-", listen))
