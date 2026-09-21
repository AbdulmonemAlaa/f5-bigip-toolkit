#!/usr/bin/env python3

#######################################################
# split_attacks_to_xlsx.py
#######################################################
#
# Author:
#   Eng. Abdulmonem Alaa Aldeen
#
# Purpose:
#   Split a "Security::DoS Config" export (for example the
#   daily log written by f5_dos_monitor.sh) into one Excel
#   file per DoS attack vector, so each vector's history
#   can be reviewed when tuning AFM DoS thresholds.
#
#   The script:
#     - Detects attack vectors and their attributes automatically
#     - Reads both timestamp formats: the plain date line printed by tmsh
#       and the "[YYYY-MM-DD HH:MM:SS]" marker written by f5_dos_monitor.sh
#     - Keeps one row per sample (144 rows = one day at 10-minute intervals)
#     - Skips empty lines (prevents a blank first column)
#     - Drops the columns: timestamp, Detection Method, Status
#     - Writes summary.csv with the number of rows per attack
#
# Requirements:
#   pip install pandas openpyxl python-dateutil
#
# Usage:
#   python split_attacks_to_xlsx.py --infile full_dump.txt --outdir out_attacks
#
# Outputs (generated in --outdir):
#   - <attack_name>.xlsx : one file per attack vector (sheet "history")
#   - summary.csv        : rows per attack (name can be changed with --summary)
#
#######################################################


#######################################################
# Imports
#######################################################

import re
import sys
import argparse
from pathlib import Path
from collections import defaultdict, OrderedDict
from datetime import datetime
from typing import List, Dict, Optional

import pandas as pd
from dateutil import parser as dtparser


#######################################################
# Configuration (optional)
#######################################################

# Fix the order of attacks (leave empty = sorted by name)
ATTACK_NAMES: List[str] = []

# Fix the column order (leave empty = order found in the input)
ATTRIBUTES: List[str] = []

# Columns to drop from the final Excel files
COLUMNS_TO_IGNORE: List[str] = ["timestamp", "Detection Method", "Status"]

# Regex patterns
HEADER_REGEX = r"^Security::DoS Config:\s*(.+)$"
KV_REGEX     = r"^\s{2,}(.+?)\s{2,}(.+?)\s*$"

# Two timestamp formats can start a sample:
#   1) the default `date` output, e.g.
#        Thu Sep 18 09:10:01 UTC 2025
#   2) the bracketed marker written by f5_dos_monitor.sh, e.g.
#        [2025-09-18 09:10:01] ===== TMSH Command =====
TS_REGEX     = r"^[A-Z][a-z]{2} [A-Z][a-z]{2} \d{1,2} \d{2}:\d{2}:\d{2} .+ \d{4}$"
TS_BRACKETED = r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]"

INVALID_SHEET_CHARS = r'[\[\]\:\*\?\/\\]'
SHEET_MAX = 31


#######################################################
# Functions
#######################################################

def parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument("--infile", required=True, help="Input text file containing attack logs")
    ap.add_argument("--outdir", required=True, help="Output folder for Excel files")
    ap.add_argument("--summary", default="summary.csv", help="Summary CSV filename")
    return ap.parse_args()

def parse_timestamp(line: str) -> Optional[datetime]:
    s = line.strip()

    # f5_dos_monitor.sh marker: take the timestamp out of the brackets and
    # ignore whatever text follows it on the same line.
    m = re.match(TS_BRACKETED, s)
    if m:
        s = m.group(1)
    elif not re.match(TS_REGEX, s):
        return None

    try:
        dt = dtparser.parse(s)
        if dt.tzinfo is not None:
            dt = dt.replace(tzinfo=None)
        return dt
    except Exception:
        return None

def sanitize_sheet_name(name: str) -> str:
    safe = re.sub(INVALID_SHEET_CHARS, "_", name)
    return safe[:SHEET_MAX - 3] + "..." if len(safe) > SHEET_MAX else safe

def load_records(lines: List[str]) -> Dict[str, List[dict]]:
    hdr_re = re.compile(HEADER_REGEX)
    kv_re  = re.compile(KV_REGEX)

    records_by_attack = defaultdict(list)
    current_ts = None
    current_attack = None
    current_rec = None

    def flush():
        if current_attack and current_rec:
            rec = dict(current_rec)
            rec["_timestamp"] = current_ts
            records_by_attack[current_attack].append(rec)

    for line in lines:
        line = line.rstrip("\n")
        if not line.strip():
            continue  # skip empty lines

        ts = parse_timestamp(line)
        if ts:
            flush()
            current_ts = ts
            current_attack = None
            current_rec = None
            continue

        m_hdr = hdr_re.match(line.strip())
        if m_hdr:
            flush()
            current_attack = m_hdr.group(1).strip()
            current_rec = OrderedDict()
            continue

        if current_attack:
            m_kv = kv_re.match(line)
            if m_kv:
                key = m_kv.group(1).strip()
                val = m_kv.group(2).strip()
                if re.fullmatch(r"\d+", val):
                    try:
                        val = int(val)
                    except Exception:
                        pass
                current_rec[key] = val

    flush()
    return records_by_attack

def ensure_columns(df: pd.DataFrame, attributes: List[str]) -> pd.DataFrame:
    desired = ["timestamp"] + list(attributes)
    for c in desired:
        if c not in df.columns:
            df[c] = pd.NA
    ordered = desired + [c for c in df.columns if c not in desired]
    return df[ordered]


#######################################################
# Main
#######################################################

def main():
    args = parse_args()
    infile = Path(args.infile)
    outdir = Path(args.outdir)

    lines = infile.read_text(errors="ignore").splitlines()
    records_by_attack = load_records(lines)

    # Nothing recognised: stop with a clear message instead of failing later
    # on an empty summary frame. Checked before the output folder is created,
    # so a failed run leaves nothing behind.
    if not records_by_attack:
        print(
            "ERROR: no 'Security::DoS Config:' blocks found in %s\n"
            "       Expected a capture of 'tmsh show security dos device-config',\n"
            "       for example a daily log written by f5_dos_monitor.sh." % infile,
            file=sys.stderr,
        )
        raise SystemExit(1)

    outdir.mkdir(parents=True, exist_ok=True)

    if ATTACK_NAMES:
        attacks = ATTACK_NAMES
    else:
        attacks = sorted(records_by_attack.keys())

    if ATTRIBUTES:
        attributes = ATTRIBUTES
    else:
        seen = OrderedDict()
        for atk in attacks:
            for rec in records_by_attack.get(atk, []):
                for k in rec.keys():
                    if k != "_timestamp" and k not in seen:
                        seen[k] = True
        attributes = list(seen.keys())

    summary_rows = []

    for attack in attacks:
        recs = records_by_attack.get(attack, [])
        rows = []
        for r in recs:
            row = dict(r)
            row["timestamp"] = row.pop("_timestamp", None)
            rows.append(row)
        df = pd.DataFrame(rows)

        if not df.empty and "timestamp" in df.columns and df["timestamp"].notna().any():
            df = df.sort_values("timestamp")

        df = ensure_columns(df, attributes)

        # Remove unwanted columns (and skip blank names)
        keep_cols = [c for c in df.columns if c not in COLUMNS_TO_IGNORE and c.strip()]
        df = df[keep_cols]

        file_stem = re.sub(r"[^A-Za-z0-9_.-]+", "_", attack)[:120] or "attack"
        xlsx_path = outdir / f"{file_stem}.xlsx"
        with pd.ExcelWriter(xlsx_path, engine="openpyxl") as writer:
            df.to_excel(writer, sheet_name="history", index=False)

        summary_rows.append({
            "attack": attack,
            "rows": len(df),
            "file": xlsx_path.name
        })

    # Explicit columns so the sort is safe even if no rows were produced
    # (e.g. ATTACK_NAMES pinned to vectors that are absent from the input).
    summary_df = pd.DataFrame(summary_rows, columns=["attack", "rows", "file"])
    if not summary_df.empty:
        summary_df = summary_df.sort_values(["rows", "attack"], ascending=[False, True])
    summary_df.to_csv(outdir / args.summary, index=False)

    print(f"Done. Wrote {len(attacks)} Excel files to: {outdir}")
    print(f"Summary CSV: {outdir / args.summary}")

if __name__ == "__main__":
    main()
