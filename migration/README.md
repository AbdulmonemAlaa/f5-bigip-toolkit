# migration/

Helpers for moving LTM virtual servers between BIG-IP boxes, tenants or partitions.

Typical order of work:

1. `check_vs_ssl_profiles.sh` and `check_vs_stats.sh` on the **old** box — capture what exists.
2. `build_cleanup_commands.sh` on the **old** box — generate the teardown and rebuild commands.
3. Run `delete.bash` on the old box (review it first — see below), `create.bash` on the new box.
4. `check_vs_stats.sh` on the **new** box — compare against the old output.

All three scripts take the same kind of input: a text file with **one virtual server name per
line**. Blank lines and lines starting with `#` are skipped.

Example `vs_list.txt` (all names invented):

```
# customer-facing apps
app1_vip_443
app1_vip_80
web-frontend_vip_443
portal_vip_8443

# internal
intranet_vip_80
```

---

## `build_cleanup_commands.sh`

```bash
sed -i 's/\r$//' build_cleanup_commands.sh
chmod +x build_cleanup_commands.sh
./build_cleanup_commands.sh <vs_list_file> <cleanup_interface>
```

| Argument | Meaning |
| --- | --- |
| `<vs_list_file>` | Text file with one virtual server name per line |
| `<cleanup_interface>` | The interface or trunk that `delete.bash` removes from each VLAN — for example `1.1`, `1.3` or `uplink-trunk`. **Required.** |

Example:

```bash
./build_cleanup_commands.sh vs_list.txt 1.1
```

For each virtual server the script finds the VIP address, resolves the VLAN (first by matching the
VIP subnet against the self-IPs, then by name as a fallback), locates the floating and
non-floating self-IPs, and reads the default pool, its members and their states.

Produces, in the current directory:

| File | Contents |
| --- | --- |
| `delete.bash` | Old box: detach `<cleanup_interface>` from each VLAN, delete the self-IPs |
| `create.bash` | New box: re-enable/disable virtual servers, restore pool member and node states, recreate the self-IPs |
| `vlan_list.csv` | Unique VLANs used by the selected VIPs, with their tags |
| `vip_asm_policies.csv` | Which VIPs have an ASM policy attached, and its name |

Progress and warnings go to stderr, so you can watch the run and still redirect cleanly.

> ⚠️ `delete.bash` is destructive. Read it in full, confirm the device and partition, and take a
> UCS backup before running it. See the warning in the [main README](../README.md).

VLANs are **not** created automatically on the new box — use `vlan_list.csv` and create/attach
them yourself, then apply any ASM policies listed in `vip_asm_policies.csv`.

---

## `check_vs_ssl_profiles.sh`

```bash
sed -i 's/\r$//' check_vs_ssl_profiles.sh
chmod +x check_vs_ssl_profiles.sh
./check_vs_ssl_profiles.sh vs_list.txt > vip_ssl_report.csv
```

Writes CSV to stdout, one row per virtual server, with the client-SSL and server-SSL profiles and
for each of them the certificate, key and chain, plus the server-SSL `ca-file`,
`peer-cert-mode`, `server-name` and `sni-default`. Fields that are not configured read
`(not-set)`. Profile lookups are cached, so repeated profiles across many VIPs cost nothing.

Example output (invented values):

```csv
VS_Name,ClientSSL_Profiles,Client_Cert,Client_Key,...
app1_vip_443,"clientssl_app1","clientssl_app1=/Common/app1.crt","clientssl_app1=/Common/app1.key",...
web-frontend_vip_443,"clientssl_web","clientssl_web=/Common/web.crt","clientssl_web=/Common/web.key",...
```

A virtual server that cannot be found produces a row of empty fields rather than stopping the run.

---

## `check_vs_stats.sh`

```bash
sed -i 's/\r$//' check_vs_stats.sh
chmod +x check_vs_stats.sh
./check_vs_stats.sh vs_list.txt > all_stats.csv
```

Writes CSV to stdout with one row per object and a blank line between virtual server blocks so it
reads well in Excel:

| `Type` | Row describes |
| --- | --- |
| `VS` | The virtual server |
| `POOL` | Its default pool |
| `MEMBER` | Each pool member |

Columns: `Type,VS_Name,Pool_Name,Member_Name,Member_IP,Availability,State,Bits_In,Bits_Out,Packets_In,Packets_Out,Cur_Conn,Max_Conn,Total_Conn,Reason`.

Run it on both sides of a migration and diff the results:

```bash
# on the old box, before
./check_vs_stats.sh vs_list.txt > all_stats_old.csv

# on the new box, after
./check_vs_stats.sh vs_list.txt > all_stats_new.csv
```

Missing objects are reported in-band as `NOT_FOUND` / `NO_POOL` rows instead of failing.
