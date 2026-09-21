#!/bin/bash

#######################################################
# check_vs_stats.sh
#######################################################
#
# Author:
#   Eng. Abdulmonem Alaa Aldeen
#
# Purpose:
#   Collect live statistics for:
#     - Each virtual server in vs_list.txt
#     - Its default pool (if any)
#     - All pool members of that pool
#
#   Output is a single CSV (all_stats.csv) with one row per object:
#     Type=VS      → virtual server stats
#     Type=POOL    → default pool stats
#     Type=MEMBER  → each pool member stats
#
#   A blank line is added between VS blocks for Excel readability.
#
# Output columns:
#   Type,VS_Name,Pool_Name,Member_Name,Member_IP,Availability,State, \
#   Bits_In,Bits_Out,Packets_In,Packets_Out,Cur_Conn,Max_Conn,Total_Conn,Reason
#
# Usage:
#   sed -i 's/\r$//' check_vs_stats.sh
#   chmod +x check_vs_stats.sh
#   ./check_vs_stats.sh vs_list.txt > all_stats.csv
#
# Recommended workflow:
#   - Run once on OLD box before migration  → all_stats_old.csv
#   - Run once on NEW box after migration  → all_stats_new.csv
#   - Compare VS/POOL/MEMBER availability, health, and traffic.
#
#######################################################


#######################################################
# Configuration / input handling
#######################################################

INPUT_FILE="$1"

if [[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]]; then
  echo "Usage: $0 <vs_list_file>" >&2
  exit 1
fi

# CSV Header
echo "Type,VS_Name,Pool_Name,Member_Name,Member_IP,Availability,State,Bits_In,Bits_Out,Packets_In,Packets_Out,Cur_Conn,Max_Conn,Total_Conn,Reason"

while read VS; do
  [[ -z "$VS" || "$VS" =~ ^# ]] && continue


  #######################################################
  # Virtual Server stats
  #######################################################

  OUT=$(tmsh show ltm virtual "$VS" all-properties 2>/dev/null)

  if [[ -z "$OUT" ]]; then
    echo "VS,$VS,,,,NOT_FOUND,NOT_FOUND,0,0,0,0,0,0,0,Virtual server not found"
    continue
  fi

  AVAIL=$(echo "$OUT"  | awk -F': ' '/Availability/ {print $2; exit}')
  STATE=$(echo "$OUT"  | awk -F': ' '/State/        {print $2; exit}')
  REASON=$(echo "$OUT" | awk -F': ' '/Reason/       {print $2; exit}')

  BITS_IN=$(echo "$OUT"      | awk '/Bits In/              {print $3; exit}')
  BITS_OUT=$(echo "$OUT"     | awk '/Bits Out/             {print $3; exit}')
  PKTS_IN=$(echo "$OUT"      | awk '/Packets In/           {print $3; exit}')
  PKTS_OUT=$(echo "$OUT"     | awk '/Packets Out/          {print $3; exit}')
  CURR=$(echo "$OUT"         | awk '/Current Connections/  {print $3; exit}')
  MAXC=$(echo "$OUT"         | awk '/Maximum Connections/  {print $3; exit}')
  TOTAL=$(echo "$OUT"        | awk '/Total Connections/    {print $3; exit}')

  AVAIL=${AVAIL:-unknown}
  STATE=${STATE:-unknown}
  REASON=${REASON:-}
  REASON=${REASON//,/;}

  echo "VS,$VS,,,,$AVAIL,$STATE,$BITS_IN,$BITS_OUT,$PKTS_IN,$PKTS_OUT,$CURR,$MAXC,$TOTAL,$REASON"


  #######################################################
  # Pool stats
  #######################################################

  VS_LINE=$(tmsh list ltm virtual "$VS" one-line 2>/dev/null)
  POOL_FULL=$(echo "$VS_LINE" | sed -n 's/.* pool \([^ ]*\) .*/\1/p')
  POOL_NAME=${POOL_FULL##*/}

  if [[ -n "$POOL_FULL" ]]; then
    POUT=$(tmsh show ltm pool "$POOL_FULL" all-properties 2>/dev/null)

    if [[ -n "$POUT" ]]; then
      P_AVAIL=$(echo "$POUT"  | awk -F': ' '/Availability/ {print $2; exit}')
      P_STATE=$(echo "$POUT"  | awk -F': ' '/State/        {print $2; exit}')
      P_REASON=$(echo "$POUT" | awk -F': ' '/Reason/       {print $2; exit}')

      P_BITS_IN=$(echo "$POUT"      | awk '/Bits In/              {print $3; exit}')
      P_BITS_OUT=$(echo "$POUT"     | awk '/Bits Out/             {print $3; exit}')
      P_PKTS_IN=$(echo "$POUT"      | awk '/Packets In/           {print $3; exit}')
      P_PKTS_OUT=$(echo "$POUT"     | awk '/Packets Out/          {print $3; exit}')
      P_CURR=$(echo "$POUT"         | awk '/Current Connections/  {print $3; exit}')
      P_MAXC=$(echo "$POUT"         | awk '/Maximum Connections/  {print $3; exit}')
      P_TOTAL=$(echo "$POUT"        | awk '/Total Connections/    {print $3; exit}')

      P_AVAIL=${P_AVAIL:-unknown}
      P_STATE=${P_STATE:-unknown}
      P_REASON=${P_REASON:-}
      P_REASON=${P_REASON//,/;}

      echo "POOL,$VS,$POOL_NAME,,$POOL_NAME,$P_AVAIL,$P_STATE,$P_BITS_IN,$P_BITS_OUT,$P_PKTS_IN,$P_PKTS_OUT,$P_CURR,$P_MAXC,$P_TOTAL,$P_REASON"
    else
      echo "POOL,$VS,$POOL_NAME,,,NOT_FOUND,NOT_FOUND,0,0,0,0,0,0,0,Pool not found"
    fi
  else
    echo "POOL,$VS,,,,NO_POOL,NO_POOL,0,0,0,0,0,0,0,Virtual server has no default pool"
  fi


  #######################################################
  # Pool Members (PARSE BLOCKS ONLY)
  #######################################################

  if [[ -n "$POOL_FULL" ]]; then
    PMOUT=$(tmsh show ltm pool "$POOL_FULL" members 2>/dev/null)
    [[ -z "$PMOUT" ]] && continue

    CURRENT_MEMBER=""
    M_ADDR=""
    M_AVAIL=""; M_STATE=""; M_REASON=""
    M_BITS_IN=""; M_BITS_OUT=""; M_PKTS_IN=""; M_PKTS_OUT=""
    M_CURR=""; M_MAXC=""; M_TOTAL=""

    flush_member() {
      local mem="$1"
      [[ -z "$mem" ]] && return 0

      local ip="${M_ADDR:-}"
      [[ -n "$ip" ]] && ip="$ip:${mem##*:}"  # attach port

      echo "MEMBER,$VS,$POOL_NAME,$mem,$ip,${M_AVAIL:-unknown},${M_STATE:-unknown},${M_BITS_IN:-0},${M_BITS_OUT:-0},${M_PKTS_IN:-0},${M_PKTS_OUT:-0},${M_CURR:-0},${M_MAXC:-0},${M_TOTAL:-0},${M_REASON//,/;}"
    }

    while IFS= read -r line; do

      if echo "$line" | grep -q "Ltm::Pool Member:"; then
        [[ -n "$CURRENT_MEMBER" ]] && flush_member "$CURRENT_MEMBER"

        CURRENT_MEMBER=$(echo "$line" | sed -n 's/.*Ltm::Pool Member:[[:space:]]*\(.*\)$/\1/p')

        M_ADDR=""
        M_AVAIL=""; M_STATE=""; M_REASON=""
        M_BITS_IN=""; M_BITS_OUT=""
        M_PKTS_IN=""; M_PKTS_OUT=""
        M_CURR=""; M_MAXC=""; M_TOTAL=""

        continue
      fi

      [[ -z "$CURRENT_MEMBER" ]] && continue

      case "$line" in
        *"IP Address"*|*"Address"*)
          M_ADDR=$(echo "$line" | awk '{print $NF}')
          ;;
        *"Availability"*)
          M_AVAIL=$(echo "$line" | awk -F': ' '{print $2}')
          ;;
        *" State "*)
          M_STATE=$(echo "$line" | awk -F': ' '{print $2}')
          ;;
        *"Reason"*)
          M_REASON=$(echo "$line" | awk -F': ' '{print $2}')
          ;;
        *"Bits In"*)
          M_BITS_IN=$(echo "$line" | awk '{print $(NF-1)}')
          ;;
        *"Bits Out"*)
          M_BITS_OUT=$(echo "$line" | awk '{print $(NF-1)}')
          ;;
        *"Packets In"*)
          M_PKTS_IN=$(echo "$line" | awk '{print $(NF-1)}')
          ;;
        *"Packets Out"*)
          M_PKTS_OUT=$(echo "$line" | awk '{print $(NF-1)}')
          ;;
        *"Current Connections"*)
          M_CURR=$(echo "$line" | awk '{print $(NF-1)}')
          ;;
        *"Maximum Connections"*)
          M_MAXC=$(echo "$line" | awk '{print $(NF-1)}')
          ;;
        *"Total Connections"*)
          M_TOTAL=$(echo "$line" | awk '{print $(NF-1)}')
          ;;
      esac

    done <<< "$PMOUT"

    [[ -n "$CURRENT_MEMBER" ]] && flush_member "$CURRENT_MEMBER"
  fi

  echo ""
done < "$INPUT_FILE"