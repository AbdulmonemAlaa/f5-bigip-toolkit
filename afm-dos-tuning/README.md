# afm-dos-tuning/

Tools for tuning AFM DoS device thresholds from observed traffic instead of guesswork.

The idea: sample `tmsh show security dos device-config` every 10 minutes for a full day, then turn
that log into one spreadsheet per attack vector so you can see each vector's real rate over time
before deciding on detection and rate-limit values.

1. `f5_dos_monitor.sh` — runs on the BIG-IP, collects the samples.
2. `split_attacks_to_xlsx.py` — runs anywhere with Python, turns the log into spreadsheets.

---

## `f5_dos_monitor.sh`

Runs `tmsh show security dos device-config` every 10 minutes, appending to a per-day log. At
23:50 it takes a final sample, waits for midnight, and starts the next day's folder automatically.

First time only — copy it onto the BIG-IP under `/var/tmp`, then prepare it:

```bash
cp f5_dos_monitor.sh /var/tmp/
sed -i 's/\r$//' /var/tmp/f5_dos_monitor.sh
chmod +x /var/tmp/f5_dos_monitor.sh
```

Start it in the background:

```bash
nohup /var/tmp/f5_dos_monitor.sh > /dev/null 2>&1 &
```

Check it is running, and watch it work:

```bash
ps aux | grep f5_dos_monitor | grep -v grep
tail -f /var/tmp/f5_monitor_debug.log
```

Stop it:

```bash
pkill -9 -f f5_dos_monitor.sh
```

If you are replacing a running copy, stop it and clear the old state first:

```bash
pkill -9 -f f5_dos_monitor.sh
rm -f /var/tmp/f5_dos_monitor.pid
rm -f /var/tmp/f5_monitor_debug.log
```

The script refuses to start while another copy is running, so a second `nohup` by mistake is a
no-op instead of two loops appending duplicate samples to the same daily log. A PID file left
behind by `kill -9` is recognised as stale and cleared automatically, so you will not be locked
out after a hard kill.

Note that `pkill -9` cannot be trapped, so the PID file survives it — that is what the stale check
is for. A plain `pkill -f f5_dos_monitor.sh` (SIGTERM) exits cleanly and removes the PID file
itself, though it can take up to a minute to take effect because the loop is inside `sleep 60`.

Outputs:

| Path | Contents |
| --- | --- |
| `/var/tmp/YYYY-MM-DD/tmsh_dos_monitor.log` | The samples for that day |
| `/var/tmp/f5_monitor_debug.log` | Debug trace across all days |
| `/var/tmp/f5_dos_monitor.pid` | PID of the running instance |

A full day at 10-minute intervals is 144 samples.

> Note: the logs live under `/var/tmp`, which is not preserved across a BIG-IP upgrade. Copy the
> day folder off the box once you are done collecting.

---

## `split_attacks_to_xlsx.py`

```bash
pip install pandas openpyxl python-dateutil
python split_attacks_to_xlsx.py --infile full_dump.txt --outdir out_attacks
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--infile` | *(required)* | The collected log, e.g. a day's `tmsh_dos_monitor.log` |
| `--outdir` | *(required)* | Folder to write the spreadsheets into (created if missing) |
| `--summary` | `summary.csv` | Name of the summary file written inside `--outdir` |

The script detects each `Security::DoS Config:` block and its attributes automatically — you do
not list the vectors up front. Each sample becomes one row, sorted by timestamp, on a sheet named
`history`. The `timestamp`, `Detection Method` and `Status` columns are dropped from the output;
edit `COLUMNS_TO_IGNORE` near the top of the script to change that. `ATTACK_NAMES` and
`ATTRIBUTES` can likewise be set to pin the file order or the column order.

Example — input (invented values):

```
Thu Sep 18 09:10:01 UTC 2025
Security::DoS Config: tcp-syn-flood
  Detection Method       Rate
  Rate Threshold         30000
  Rate Increase          500
  Rate Limit             40000
  Status                 detect-only
Security::DoS Config: udp-flood
  Detection Method       Rate
  Rate Threshold         20000
  Rate Increase          500
  Rate Limit             25000
  Status                 detect-only
```

and output:

```
out_attacks/
  tcp-syn-flood.xlsx     sheet "history", one row per sample
  udp-flood.xlsx         sheet "history", one row per sample
  summary.csv            attack,rows,file - sorted by row count
```

Attack names become file names with unsafe characters replaced by `_`. Every file holds a single
sheet named `history`.

If the input contains no `Security::DoS Config:` blocks, the script stops with an error naming the
file rather than writing a folder of empty spreadsheets — usually a sign the capture is of the
wrong command.
