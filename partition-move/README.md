# partition-move/

Helpers for moving LTM applications from one administrative partition to another — for example
from a legacy partition into `/Common` — and, when needed, from one route domain to another.

A partition move is not a rename. An object in `/Common` cannot reference anything in another
partition, so every pool, node, monitor, profile, iRule, data-group and virtual address the
virtual server uses has to move with it, in the right order, without taking away anything another
application still uses. These scripts work that out from the running configuration and write the
change files for you to review and run.

| Script | Purpose | Changes the box? |
| --- | --- | --- |
| `f5_partition_move.py discover` | Walk everything the virtual servers depend on and classify each object | No |
| `f5_partition_move.py generate` | Same discovery, then a job folder with numbered change scripts | No — writes files only |
| `vlan_scope.py` | Everything that belongs to one server VLAN: subnets, nodes, pools, virtual servers | No |
| `rd_check.py` | Route domains, connected subnets and routes, and how a target route domain reaches each address | No |

All three run **on the BIG-IP** with the system `python3` (standard library only). They read the
running configuration from a temporary single-file snapshot (`tmsh save sys config file ...`),
which does not touch `/config`; the snapshot and its `.tar` (it holds certificate and key copies)
are deleted straight away. `--scf <file>` reuses a snapshot you saved yourself instead.

Typical order of work:

1. `vlan_scope.py` or `discover` — find what belongs to the application.
2. `rd_check.py` — if the route domain changes, check the servers stay reachable and note any route
   to add.
3. `generate` — write the job folder, read it.
4. Run the job scripts in order (see [Run order](#run-order)).

Copy the scripts to the box first, for example:

```bash
mkdir -p /shared/partition-move
# scp f5_partition_move.py vlan_scope.py rd_check.py to /shared/partition-move/, then:
cd /shared/partition-move
sed -i 's/\r$//' *.py
```

`vlan_scope.py` and `rd_check.py` import the parser from `f5_partition_move.py`, so keep the three
files in the same folder.

---

## `f5_partition_move.py discover`

```bash
python3 f5_partition_move.py discover --src Legacy --vs app1_vip_443 --vs app1_vip_80
python3 f5_partition_move.py discover --src Legacy --vs-file vs_list.txt --json app1_discovery.json
python3 f5_partition_move.py discover --src Legacy --all        # every virtual server in the partition
```

| Argument | Meaning |
| --- | --- |
| `--src` | Source partition. **Required.** |
| `--dst` | Destination partition (default `Common`) |
| `--vs` | Virtual server name, repeatable. Short name (looked up in `--src`) or full path |
| `--vs-file` | Text file, one virtual server per line; blank lines and `#` lines skipped |
| `--pool` | A pool that no virtual server uses but should move too (for example one only an iRule selects) |
| `--all` | Every virtual server in the source partition — for planning |
| `--json` | Also write the result as JSON |
| `--scf` | Use a saved single-file config instead of a fresh snapshot |

Every object found gets one status:

| Status | Meaning | What `generate` does |
| --- | --- | --- |
| `MOVE` | In the source partition, used only by what is moving | Creates it in the destination |
| `SHARED` | Also used by something that is **not** moving | Stops — move the other users too, or keep a copy |
| `CONFLICT-SAME` | Same name already in the destination, identical configuration | Reuses the existing object, re-points to it |
| `CONFLICT-DIFF` | Same name already in the destination, **different** configuration | Stops — decide per object |
| `BLOCKER` | A VLAN, self IP, route domain or object in a third partition | Stops (a VLAN can be solved with `--vlans all`) |
| `COMMON` | Already in `/Common` (including built-ins such as `tcp`, `http`) | Left alone |

Comparisons ignore the partition path, take route domains into account, and mask encrypted
`$M$...` values (they use a random IV and never compare equal as text — check secrets yourself
before reusing a `CONFLICT-SAME` object). Names that appear inside iRule text (pools, data-groups,
SNAT pools, nodes, virtual servers) are followed too, and flagged for review.

Example (invented sample config — `Legacy` uses route domain 11):

```
partition-move discovery  Legacy -> Common
route domains: Legacy default RD 11 | Common default RD 0
----------------------------------------------------------------------------------------------------
MOVE      ltm virtual /Legacy/app1_vip_443
    MOVE      ltm persistence cookie /Legacy/app1_cookie
    MOVE      ltm pool /Legacy/app1_pool   <- referenced inside iRule text: review the iRule after the move; ...
        MOVE      ltm monitor http /Legacy/app1_http_mon
        MOVE      ltm node /Legacy/192.0.2.21   <- address(es) 192.0.2.21 are in route domain 11 (partition default); ...
        MOVE      ltm node /Legacy/192.0.2.22   <- ...
    COMMON    ltm profile (built-in) /Common/clientssl
    COMMON    ltm profile (built-in) /Common/tcp
    MOVE      ltm profile http /Legacy/app1_http
    MOVE      ltm rule /Legacy/app1_sorry
        MOVE      ltm data-group internal /Legacy/app1_allowed_paths   <- referenced inside iRule text: ...
        MOVE      ltm pool /Legacy/app1_sorry_pool   <- ...
    MOVE      ltm virtual-address /Legacy/203.0.113.10   <- ...
    BLOCKER   net vlan /Legacy/app-clients   <- net vlan in partition Legacy - the virtual server LISTENS on it ...
----------------------------------------------------------------------------------------------------
SUMMARY
  MOVE           12  ltm data-group internal=1, ltm monitor http=1, ltm node=2, ltm persistence cookie=1, ...
  SHARED          0
  CONFLICT-SAME   0
  CONFLICT-DIFF   0
  BLOCKER         1  net vlan=1
  COMMON          5  ltm monitor (built-in)=1, ltm profile (built-in)=3, ltm rule (built-in)=1
```

---

## `f5_partition_move.py generate`

```bash
python3 f5_partition_move.py generate --src Legacy --dst Common \
    --vs app1_vip_443 --vs app1_vip_80 \
    --vlans all \
    --route app_servers_net,192.0.2.0/24,198.51.100.254 \
    --out /shared/partition-move/jobs/app1
```

Takes the same `--src`, `--dst`, `--vs`, `--vs-file`, `--pool` and `--scf` as `discover`, plus:

| Argument | Meaning |
| --- | --- |
| `--out` | Job folder to write. **Required.** Its name is also the job name (used for the UCS file name) |
| `--target-rd` | Route domain of the moved objects. Default: the destination partition's default route domain |
| `--vlans keep` | Default. The virtual servers keep their VLAN list — those VLANs must already be in `/Common` (a VLAN in the source partition is a `BLOCKER`) |
| `--vlans all` | The virtual servers listen on **every** VLAN of the target route domain (`vlans-disabled`, empty list) |
| `--route NAME,NETWORK,GATEWAY` | A static route the servers need in the target route domain. Repeatable. `NETWORK` can be `default` |

It refuses to write anything while there is a `SHARED`, `CONFLICT-DIFF` or `BLOCKER` object, or a
certificate/key in the source partition (copying certificate files is not automated — import them
into the destination first, then run it again).

The job folder:

| File | What it does | Changes the box? |
| --- | --- | --- |
| `00_discovery.txt` | The discovery report, for the change record | No |
| `01_precheck.sh` | Every source object exists, every target name is free; saves `pre_<job>.ucs` | Saves a UCS |
| `10_create_<dst>.conf` | The new objects, already rewritten for the destination partition and route domain | — |
| `11_create.sh` | `load sys config merge ... verify`, then the real merge, then `save sys config` | **Yes** |
| `12_route_<dst>.conf`, `12_add_route.sh` | Only with `--route`: the route(s), loaded the same way | **Yes** |
| `20_verify.sh` | Destination, pool, VLANs and availability of the new virtual servers and pools | No |
| `30_delete_<src>.sh` | Deletes the original objects, in reverse dependency order | **Yes** |
| `90_rollback_<src>.conf` | The original objects, unchanged | — |
| `91_rollback.sh` | Deletes the new objects, then reloads the originals | **Yes** |
| `92_remove_route.sh` | Only with `--route`: removes the route(s) | **Yes** |

Existence checks inside the scripts read the folder listing rather than `tmsh list <object>`, so a
missing object does not write an error line to `/var/log/ltm`.

### Run order

**Target route domain differs from the source's** (for example `Legacy` in RD 11 → `/Common` in
RD 0): the new objects can live next to the originals, because addresses are unique per route
domain. Build the new side ahead of time, cut over, then clean up:

```
01_precheck -> 11_create -> 12_add_route -> 20_verify
            -> [cutover: the network starts sending traffic to the new side] -> 20_verify
            -> 30_delete_<src> -> sync the device group
rollback:     91_rollback  (+ 92_remove_route)
```

**Same route domain as the source** (for example both partitions in RD 0, or `--target-rd` equal
to the source's): an address cannot exist twice in one route domain, so the originals must go
first. `generate` prints a note and marks both scripts:

```
01_precheck -> 30_delete_<src> -> 11_create -> 20_verify     (one maintenance window)
rollback:     91_rollback
```

> ⚠️ `30_delete_<src>.sh` removes the original objects and `11_create.sh` changes the running
> configuration. Read `10_create_<dst>.conf` in full, confirm you are on the active unit of the
> right device group, keep the UCS from `01_precheck.sh`, and sync the device group only when
> `20_verify.sh` looks right.

---

## `vlan_scope.py`

```bash
python3 vlan_scope.py app-servers      # by VLAN name
python3 vlan_scope.py 120              # or by tag
```

Lists the VLAN (tag, partition, route domain, self IPs and subnets), the nodes inside those subnets
in the same route domain, the pools that use them, and the virtual servers that use those pools or
whose address is inside the subnets — with the VLANs each one listens on. A virtual server with no
`vlans-enabled` line listens on every VLAN (tmsh does not print the default).

```
VLAN /Legacy/app-servers  tag=120  partition=Legacy
  route domain: /Common/legacy_rd
  self IP /Legacy/app-servers_self   192.0.2.5%11  subnet 192.0.2.0/24  /Common/traffic-group-local-only

NODES in the VLAN subnets (3): /Legacy/192.0.2.21, /Legacy/192.0.2.22, /Legacy/192.0.2.31
POOLS using them (3):
   /Legacy/app1_pool          used by: /Legacy/app1_vip_443
   /Legacy/app1_sorry_pool    used by: NO virtual server
   /Legacy/app2_pool          used by: /Legacy/app2_vip_443

VIRTUAL SERVERS in scope (2):
   /Legacy/app1_vip_443   /Legacy/203.0.113.10:443   pool=app1_pool   listens ONLY on: app-clients
   /Legacy/app2_vip_443   /Legacy/203.0.113.20:443   pool=app2_pool   listens on ALL VLANs
```

`app1_sorry_pool` is used only from an iRule — pass it to `discover`/`generate` with `--pool` if it
is not already picked up through the iRule.

---

## `rd_check.py`

```bash
python3 rd_check.py --ip 192.0.2.21 --ip 203.0.113.10            # target route domain 0
python3 rd_check.py --rd 20 --ip 192.0.2.21
```

Prints every route domain (VLANs, connected subnets, static routes), then for each address: which
route domain already uses it, which connected subnet it sits in, and how the target route domain
would reach it — connected, the longest matching static route, or not at all.

```
192.0.2.21
   used in RD 11  by ltm node /Legacy/192.0.2.21
   inside connected subnet 192.0.2.0/24 of RD 11 (self 192.0.2.5 on app-servers)
   in RD 0: static route 0.0.0.0/0 via gw 198.51.100.1 (/Common/default_gw)
```

Here the servers are directly connected in RD 11 but would only match the default route in RD 0 —
that is the case for `--route app_servers_net,192.0.2.0/24,<gateway>`.

---

## Limits

- IPv4 only for route-domain rewriting and for the two helper scripts.
- Certificates and keys in the source partition are reported, not copied.
- iRule text is not rewritten. Short names inside an iRule resolve in the partition the iRule lives
  in, so they follow the move — but read every iRule the report flags.
- HA: run on the active unit, then sync the device group.
