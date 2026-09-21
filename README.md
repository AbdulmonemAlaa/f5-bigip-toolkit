# f5-bigip-toolkit

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Shell and Python helpers for two recurring F5 BIG-IP tasks:

- **Migrating LTM virtual servers** between boxes, tenants or partitions — capturing the
  existing state, generating the teardown and rebuild commands, and comparing before/after.
- **Tuning AFM DoS thresholds** — sampling the device DoS configuration over a full day and
  turning that log into one spreadsheet per attack vector.

Everything runs directly on the BIG-IP shell using `tmsh`, except the Python tool, which runs
wherever you collect the logs.

## Tools

| Tool | Folder | Purpose |
| --- | --- | --- |
| `build_cleanup_commands.sh` | `migration/` | Read a list of virtual servers and generate `delete.bash` (old box), `create.bash` (new box), `vlan_list.csv` and `vip_asm_policies.csv` |
| `check_vs_ssl_profiles.sh` | `migration/` | CSV report of the client-SSL and server-SSL profiles on each virtual server, with cert, key, chain, CA file, peer-cert-mode, server name and SNI default |
| `check_vs_stats.sh` | `migration/` | CSV of live availability, state and traffic counters for each virtual server, its default pool and every pool member |
| `f5_dos_monitor.sh` | `afm-dos-tuning/` | Run `tmsh show security dos device-config` every 10 minutes, logging into per-day folders and rolling over at midnight |
| `split_attacks_to_xlsx.py` | `afm-dos-tuning/` | Split that log into one `.xlsx` per DoS attack vector, plus a `summary.csv` |

## Requirements

- F5 BIG-IP with shell (bash) access and `tmsh` on `PATH` — the four shell scripts run on the
  BIG-IP itself.
- Python 3.8+ for `split_attacks_to_xlsx.py`, with:

  ```bash
  pip install pandas openpyxl python-dateutil
  ```

The scripts are read-only against the BIG-IP: they collect configuration and statistics and write
files to the current directory. The only script that produces changes is
`build_cleanup_commands.sh`, and even then it *writes command files* rather than applying them.

## ⚠️ Review `delete.bash` before you run it

`build_cleanup_commands.sh` generates `delete.bash`, which contains commands that **remove
self-IPs and detach an interface from VLANs on a live BIG-IP**:

```
tmsh modify net vlan <vlan> interfaces delete { <interface> }
tmsh delete net self <floating-self>
tmsh delete net self <non-floating-self>
```

Before running it:

1. Open `delete.bash` and read every line.
2. Confirm you are on the correct device, tenant and partition (`tmsh show sys hardware`,
   `tmsh show cm device`).
3. Confirm the VLANs and self-IPs listed are the ones you intend to remove — the VLAN is resolved
   by subnet match with a *name-based fallback*, so an unexpected match is possible.
4. Take a UCS backup first.

The same care applies to `create.bash`, which enables/disables virtual servers, pool members and
nodes on the target box.

## Usage

Each folder has its own README with per-script usage and a worked example:

- [`migration/README.md`](migration/README.md)
- [`afm-dos-tuning/README.md`](afm-dos-tuning/README.md)

## Notes

- No configuration, host name, address or object name from any real environment is included.
  Every example in this repository is invented.
- Generated output (`*.csv`, `*.xlsx`, `delete.bash`, `create.bash`, `vs_list*.txt`,
  `out_attacks/`) is git-ignored on purpose — those files contain real data once you run the
  tools.
- `f5_dos_monitor.sh` writes its logs under `/var/tmp`, which is **not preserved across a BIG-IP
  upgrade**. Copy the day's folder off the box once you have finished collecting, before doing
  anything to the device.

## Author

Eng. Abdulmonem Alaa Aldeen

## License

Released under the MIT License — see [LICENSE](LICENSE).
