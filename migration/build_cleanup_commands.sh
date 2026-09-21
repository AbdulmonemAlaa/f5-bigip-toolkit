#!/bin/bash

#######################################################
# build_cleanup_commands.sh
#######################################################
#
# Author:
#   Eng. Abdulmonem Alaa Aldeen
#
# Purpose:
#   Read a list of virtual servers and generate:
#     - delete.bash : cleanup commands for the OLD box/tenant
#     - create.bash : recreate/enable commands for the NEW box/tenant
#     - vlan_list.csv : unique VLANs used by the selected VIPs
#     - vip_asm_policies.csv : (if enabled) mapping of VIP → ASM policy
#
#   For each VS in vs_list.txt the script:
#     - Detects its VIP address
#     - Finds the associated VLAN and self-IPs using:
#         1) VIP ↔ self-IP subnet match (primary)
#         2) Name-based VLAN matching as a fallback (VS name vs VLAN name)
#     - Handles default pool, pool members and member/node status
#     - De-duplicates network actions per VLAN/self pair
#
# Usage:
#   sed -i 's/\r$//' build_cleanup_commands.sh
#   chmod +x build_cleanup_commands.sh
#   ./build_cleanup_commands.sh <vs_list_file> <cleanup_interface>
#
#   <vs_list_file>      : text file with one virtual server name per line
#   <cleanup_interface> : the interface or trunk that delete.bash removes
#                         from each VLAN (e.g. 1.1, 1.3, uplink-trunk)
#
#   Example:
#     ./build_cleanup_commands.sh vs_list.txt 1.1
#
# Outputs (generated in current directory):
#   - delete.bash
#   - create.bash
#   - vlan_list.csv
#   - vip_asm_policies.csv
#
# Migration workflow:
#   1) On OLD box / OLD tenant:
#        ./build_cleanup_commands.sh vs_list.txt 1.1
#        bash delete.bash
#
#   2) Copy create.bash and vlan_list.csv to NEW box.
#
#   3) On NEW box / NEW tenant:
#        bash create.bash
#
#   4) On NEW box / NEW partition:
#        Manually create/attach VLANs per vlan_list.csv
#        (and apply ASM policies if applicable).
#
#######################################################


#######################################################
# Configuration / input handling
#######################################################

INPUT_FILE="$1"
CLEAN_IF="$2"

if [[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]]; then
  echo "Usage: $0 <vs_list_file> <cleanup_interface>"
  exit 1
fi

if [[ -z "$CLEAN_IF" ]]; then
  echo "Usage: $0 <vs_list_file> <cleanup_interface>"
  echo "ERROR: cleanup interface (second argument) is required, e.g. 1.1 or uplink-trunk"
  exit 1
fi


DELETE_FILE="delete.bash"
CREATE_FILE="create.bash"

# init output files
echo "#!/bin/bash" > "$DELETE_FILE"
echo "#!/bin/bash" > "$CREATE_FILE"
echo "" >> "$DELETE_FILE"
echo "" >> "$CREATE_FILE"

VIP_ASM_FILE="vip_asm_policies.csv"
echo "VIP Name,Has ASM Policy,ASM Policy Name" > "$VIP_ASM_FILE"


#######################################################
# Helper functions
#######################################################

ip2int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

mask_from_prefix() {
  local p="$1"
  echo $(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
}

normalize_name() {
  # lower-case and replace non-alphanumeric with underscores
  echo "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]/_/g'
}

get_vs_base_name() {
  local vs="$1"
  local base="$vs"

  # Strip VIP patterns (case-insensitive):
  base=$(echo "$base" | sed -E 's/[-_]VIP[_-].*$//'I)
  base=$(echo "$base" | sed -E 's/[-_]vip[_-].*$//'I)

  # Strip trailing -PORT or _PORT (only digits)
  base=$(echo "$base" | sed -E 's/[-_]([0-9]{2,5})$//')

  echo "$base"
}

guess_vlan_from_name() {
  local vs="$1"

  local base base_norm v_norm
  base=$(get_vs_base_name "$vs")
  [[ -z "$base" ]] && return 1

  base_norm=$(normalize_name "$base")

  # Cache VLAN list once
  if [[ -z "$ALL_VLANS" ]]; then
    ALL_VLANS=$(tmsh list net vlan one-line 2>/dev/null | \
                awk '{for(i=1;i<=NF;i++) if($i=="vlan") {print $(i+1); break}}' | sort -u)
  fi

  local matches=()

  # 1) Exact normalized match
  for v in $ALL_VLANS; do
    v_norm=$(normalize_name "$v")
    if [[ "$v_norm" == "$base_norm" ]]; then
      matches+=("$v")
    fi
  done

  if [[ ${#matches[@]} -eq 1 ]]; then
    echo "${matches[0]}"
    return 0
  fi

  # 2) If no exact match, try a substring match
  if [[ ${#matches[@]} -eq 0 ]]; then
    for v in $ALL_VLANS; do
      v_norm=$(normalize_name "$v")
      if [[ "$v_norm" == *"$base_norm"* ]]; then
        matches+=("$v")
      fi
    done
  fi

  if [[ ${#matches[@]} -eq 1 ]]; then
    echo "${matches[0]}"
    return 0
  fi

  # Ambiguous or no match
  return 1
}


#######################################################
# Cached data from tmsh (self IPs, policies)
#######################################################

# cache all self IP lines once
SELF_LINES="$(tmsh list net self one-line 2>/dev/null)"

# cache all LTM policies that have an ASM action
POLICY_ASM_MAP="$(tmsh list ltm policy all one-line 2>/dev/null | grep ' asm enable policy ' || true)"

find_vlan_for_vip() {
  local vip_ip="$1"
  local vip_int
  vip_int=$(ip2int "$vip_ip")

  local best_prefix=-1
  local best_vlan=""

  local line addr ip prefix self_int mask net_self net_vip

  while IFS= read -r line; do
    addr=$(echo "$line" | sed -n 's/.* address \([0-9.\/]*\) .*/\1/p')
    [[ -z "$addr" ]] && continue

    ip="${addr%/*}"
    prefix="${addr#*/}"
    [[ -z "$prefix" ]] && continue

    self_int=$(ip2int "$ip")
    mask=$(mask_from_prefix "$prefix")
    net_self=$(( self_int & mask ))
    net_vip=$(( vip_int & mask ))

    if [[ "$net_self" -eq "$net_vip" && "$prefix" -gt "$best_prefix" ]]; then
      best_prefix="$prefix"
      best_vlan=$(echo "$line" | sed -n 's/.* vlan \([^ }]*\).*/\1/p')
    fi
  done <<< "$SELF_LINES"

  echo "$best_vlan"
}


#######################################################
# Main loop over VS list
#######################################################

# track VIP IPs that have already been processed
SEEN_VIPS=""

# Track all VLANs without duplication
UNIQUE_VLANS=()

# Track (VLAN + self IP pair) already processed for network changes
PROCESSED_NET_KEYS=()

# Track nodes already processed so we don't repeatedly emit node commands
NODES_SEEN=()

while read VS; do
  [[ -z "$VS" || "$VS" =~ ^# ]] && continue

  echo "### Processing virtual server: $VS" >&2

  VS_LINE=$(tmsh list ltm virtual "$VS" one-line 2>/dev/null)
  if [[ -z "$VS_LINE" ]]; then
    echo "###   ERROR: virtual server '$VS' not found" >&2
    echo "# ERROR: virtual server '$VS' not found" >> "$DELETE_FILE"
    echo "# ERROR: virtual server '$VS' not found" >> "$CREATE_FILE"
    echo >> "$DELETE_FILE"
    echo >> "$CREATE_FILE"
    continue
  fi


  #######################################################
  # Detect VIP state (enabled / disabled)
  #######################################################

  STATE=$(tmsh list ltm virtual "$VS" all-properties | grep -E '^[[:space:]]*(enabled|disabled)$' | tr -d ' ')
  VS_IS_DISABLED=0
  [[ "$STATE" == "disabled" ]] && VS_IS_DISABLED=1

  echo "###   VS state: $STATE" >&2


  #######################################################
  # Detect ASM policy via attached LTM policies
  #######################################################

  ASM_POLICY=""

  # Get list of LTM policies attached to this VS (if any)
  VS_POLICIES_RAW=$(echo "$VS_LINE" | sed -n 's/.* policies { \([^}]*\) }.*/\1/p')

  if [[ -n "$VS_POLICIES_RAW" && -n "$POLICY_ASM_MAP" ]]; then
    for P in $VS_POLICIES_RAW; do
      # Strip trailing '{' if present (e.g. "asm_auto_l7_policy__app1_vip_443 {")
      P=${P%\{}   # remove final '{' if it exists

      # Try to find this LTM policy (with or without /Common/ prefix)
      line=$(echo "$POLICY_ASM_MAP" | grep -E "ltm policy (/Common/)?$P " | head -1 || true)

      if [[ -n "$line" ]]; then
        # Extract the ASM policy name from the LTM policy line
        ASM_POLICY=$(echo "$line" | sed -n 's/.* asm enable policy \([^ }]*\).*/\1/p')
        if [[ -n "$ASM_POLICY" ]]; then
          break
        fi
      fi
    done
  fi

  if [[ -n "$ASM_POLICY" ]]; then
    echo "###   ASM Policy       : $ASM_POLICY" >&2
    echo "$VS,YES,$ASM_POLICY" >> "$VIP_ASM_FILE"
  else
    echo "###   ASM Policy       : <none>" >&2
    echo "$VS,NO," >> "$VIP_ASM_FILE"
  fi

  
  #######################################################
  # Detect default pool for this virtual (if any)
  #######################################################

  POOL_NAME=$(echo "$VS_LINE" | sed -n 's/.* pool \([^ ]*\) .*/\1/p' | head -1)

  if [[ -n "$POOL_NAME" ]]; then
    echo "###   Pool             : $POOL_NAME" >&2
  else
    echo "###   Pool             : <none>" >&2
  fi


  #######################################################
  # Extract VIP IP address
  #######################################################

  # Robust VIP IP extraction (works with :http, :https, :443, etc.)
  VIP_IP=$(echo "$VS_LINE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)

  if [[ -z "$VIP_IP" ]]; then
    echo "###   ERROR: Cannot extract VIP IP for VS $VS" >&2
    echo "# ERROR: Cannot extract VIP for VS $VS" >> "$DELETE_FILE"
    echo "# ERROR: Cannot extract VIP for VS $VS" >> "$CREATE_FILE"
    echo >> "$DELETE_FILE"
    echo >> "$CREATE_FILE"
    continue
  fi

  echo "###   VIP IP          : $VIP_IP" >&2

  # --- track VIPs only to help avoid duplicate network work later ---
  # (Actual dedupe is done via NET_KEY / NET_ACTION, not here.)
  if [[ " $SEEN_VIPS " == *" $VIP_IP "* ]]; then
    echo "###   VIP $VIP_IP already seen (network dedupe will use NET_KEY)" >&2
  else
    SEEN_VIPS="$SEEN_VIPS $VIP_IP"
  fi


  #######################################################
  # Resolve VLAN (priority: subnet → name-based fallback)
  #######################################################

  VLAN=""
  NET_ACTION_FORCE_SKIP=0

  # 1) Try existing subnet → self → VLAN logic
  VLAN=$(find_vlan_for_vip "$VIP_IP")
  if [[ -n "$VLAN" ]]; then
    echo "###   VLAN (from self-subnet match): $VLAN" >&2
  fi

  # 2) If still empty, try name-based matching from VS/VLAN naming pattern
  if [[ -z "$VLAN" ]]; then
    VLAN=$(guess_vlan_from_name "$VS")
    if [[ -n "$VLAN" ]]; then
      echo "###   VLAN (from name-based match): $VLAN" >&2
    fi
  fi

  # 3) If we still don't have a VLAN, we will skip ALL net self/VLAN operations
  if [[ -z "$VLAN" ]]; then
    echo "###   ERROR: cannot determine VLAN for VS $VS (VIP $VIP_IP)" >&2
    echo "# ERROR: No VLAN determined for VS $VS (VIP $VIP_IP) – skipping net self/VLAN ops" >> "$DELETE_FILE"
    echo "# ERROR: No VLAN determined for VS $VS (VIP $VIP_IP) – skipping net self/VLAN ops" >> "$CREATE_FILE"
    NET_ACTION_FORCE_SKIP=1
  else
    echo "###   VLAN            : $VLAN" >&2

    # Track VLAN for vlan_list.csv (only once per VLAN)
    if [[ ! " ${UNIQUE_VLANS[*]} " =~ " ${VLAN} " ]]; then
      UNIQUE_VLANS+=("$VLAN")
    fi
  fi



  #######################################################
  # Interface used in VLAN cleanup
  #######################################################

  echo "###   Using configured interface: $CLEAN_IF" >&2


  #######################################################
  # Detect self IPs on this VLAN
  #######################################################

  SELF_NON_FLOAT=""
  SELF_FLOAT=""

  VLAN_SELF_LINES=$(
    echo "$SELF_LINES" | \
      grep "vlan $VLAN"
  )

  # Loop over all self lines on this VLAN
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Extract self name
    self_name=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="self") {print $(i+1); break}}')

    # Extract traffic-group (if present)
    tg=$(echo "$line" | sed -n 's/.* traffic-group \([^ ]*\).*/\1/p')

    # Classify based on traffic-group
    case "$tg" in
      traffic-group-local-only)
        # non-floating self
        SELF_NON_FLOAT="$self_name"
        ;;
      traffic-group-1)
        # floating self
        SELF_FLOAT="$self_name"
        ;;
      *)
        # ignore other traffic-groups
        :
        ;;
    esac

  done <<< "$VLAN_SELF_LINES"


  #######################################################
  # Name-based fallback for floating self (contains float)
  #######################################################

  if [[ -z "$SELF_FLOAT" ]]; then
    VLAN_SELFS=$(
      echo "$VLAN_SELF_LINES" | \
        awk '{for(i=1;i<=NF;i++) if($i=="self") {print $(i+1); break}}' | \
        sort -u
    )

    for S in $VLAN_SELFS; do
      lname=$(echo "$S" | tr 'A-Z' 'a-z')
      if [[ "$lname" == *"float"* ]]; then
        SELF_FLOAT="$S"
        break
      fi
    done
  fi


  #######################################################
  # Name-based fallback for non-floating self (contains self)
  #######################################################

  if [[ -z "$SELF_NON_FLOAT" ]]; then
    # reuse VLAN_SELFS if it already exists, otherwise compute it
    if [[ -z "$VLAN_SELFS" ]]; then
      VLAN_SELFS=$(
        echo "$VLAN_SELF_LINES" | \
          awk '{for(i=1;i<=NF;i++) if($i=="self") {print $(i+1); break}}' | \
          sort -u
      )
    fi

    for S in $VLAN_SELFS; do
      lname=$(echo "$S" | tr 'A-Z' 'a-z')
      # pick something with "self" in the name, but not the same as floating
      if [[ "$lname" == *"self"* && "$S" != "$SELF_FLOAT" ]]; then
        SELF_NON_FLOAT="$S"
        break
      fi
    done
  fi


  #######################################################
  # Final self-IP sanity / debug
  #######################################################

  if [[ -z "$SELF_FLOAT" && -z "$SELF_NON_FLOAT" ]]; then
    echo "### ERROR: No self IPs found on VLAN $VLAN" >&2
  fi

  echo "###   Self IP          : ${SELF_NON_FLOAT:-<none>}" >&2
  echo "###   Floating Self    : ${SELF_FLOAT:-<none>}" >&2
  echo >&2


  #######################################################
  # Decide if we should do network actions for this VS
  #######################################################

  NET_KEY="${VLAN}|${SELF_NON_FLOAT}|${SELF_FLOAT}"
  NET_ACTION=1

  # If VLAN couldn't be determined → force skip
  if [[ "$NET_ACTION_FORCE_SKIP" -eq 1 || -z "$VLAN" ]]; then
    NET_ACTION=0
  else
    for K in "${PROCESSED_NET_KEYS[@]}"; do
      if [[ "$K" == "$NET_KEY" ]]; then
        NET_ACTION=0
        break
      fi
    done

    if [[ "$NET_ACTION" -eq 1 ]]; then
      PROCESSED_NET_KEYS+=("$NET_KEY")
    fi
  fi

  #######################################################
  # BUILD delete.bash  (OLD BOX)
  #######################################################

  {
    echo "# VS: $VS | VIP: $VIP_IP | VLAN: $VLAN"

    if [[ "$NET_ACTION" -eq 1 ]]; then
      echo "tmsh modify net vlan $VLAN interfaces delete { $CLEAN_IF }"

      if [[ -n "$SELF_FLOAT" ]]; then
        echo "tmsh delete net self $SELF_FLOAT"
      else
        echo "# (no floating self found on vlan $VLAN)"
      fi

      if [[ -n "$SELF_NON_FLOAT" ]]; then
        echo "tmsh delete net self $SELF_NON_FLOAT"
      else
        echo "# (no non-floating self found on vlan $VLAN)"
      fi
    else
      echo "# (network already processed for VLAN $VLAN: $SELF_NON_FLOAT / $SELF_FLOAT)"
    fi

    echo
  } >> "$DELETE_FILE"




  #######################################################
  # BUILD create.bash (NEW BOX)
  #######################################################

  {
    echo "# VS: $VS | VIP: $VIP_IP | VLAN: $VLAN"


    ###################################################
    # Virtual server state (enabled / disabled)
    ###################################################

    if [[ "$VS_IS_DISABLED" -eq 1 ]]; then
      echo "tmsh modify ltm virtual $VS disabled"
    else
      echo "tmsh modify ltm virtual $VS enabled"
    fi


    ###################################################
    # Pool, pool members, and node states
    ###################################################

    # POOL_NAME should already be set earlier from VS_LINE;
    # but just in case, derive it here as a fallback.
    if [[ -z "$POOL_NAME" ]]; then
      POOL_NAME=$(echo "$VS_LINE" | sed -n 's/.* pool \([^ ]*\) .*/\1/p' | head -1)
    fi

    if [[ -n "$POOL_NAME" ]]; then
      # Pool itself has no enabled/disabled/forced status – just record it
      echo "# Pool (no status, for reference): $POOL_NAME"

      # Get full multiline output for members of this pool
      POOL_DETAIL=$(tmsh list ltm pool "$POOL_NAME" members 2>/dev/null)

      if [[ -n "$POOL_DETAIL" ]]; then
        CURRENT_MEMBER=""
        MEMBER_SESSION=""
        MEMBER_STATE=""

        # Helper to flush one member's commands (pool member + node)
        flush_member() {
          local M_NAME="$1"
          local M_SESSION="$2"
          local M_STATE="$3"

          [[ -z "$M_NAME" ]] && return 0

          # -------- pool member state mapping --------
          # - Enabled       -> default / monitor-enabled / user-enabled / anything not user-disabled
          # - Disabled      -> user-disabled
          # - Force Offline -> user-disabled + user-down
          if [[ "$M_SESSION" == "user-disabled" && "$M_STATE" == "user-down" ]]; then
            # Force Offline
            echo "tmsh modify ltm pool $POOL_NAME members modify { $M_NAME { state user-down session user-disabled } }"
          elif [[ "$M_SESSION" == "user-disabled" ]]; then
            # Disabled
            echo "tmsh modify ltm pool $POOL_NAME members modify { $M_NAME { session user-disabled } }"
          else
            # Everything else (monitor-enabled, empty, user-enabled, etc.) => Enabled
            echo "tmsh modify ltm pool $POOL_NAME members modify { $M_NAME { session user-enabled } }"
          fi

          # -------- node state mapping --------
          local NODE_NAME="${M_NAME%:*}"
          local NODE_DETAIL NODE_SESSION NODE_STATE

          NODE_DETAIL=$(tmsh list ltm node "$NODE_NAME" 2>/dev/null)
          if [[ -z "$NODE_DETAIL" ]]; then
            echo "# Node $NODE_NAME not found (skipping)"
            return 0
          fi

          NODE_SESSION=$(echo "$NODE_DETAIL" | awk '/^[[:space:]]*session /{print $2}' | head -1)
          NODE_STATE=$(echo "$NODE_DETAIL" | awk '/^[[:space:]]*state /{print $2}' | head -1)

          # Same 3-status mapping for nodes
          if [[ -z "$NODE_STATE" && -z "$NODE_SESSION" ]]; then
            # No explicit info – assume Enabled
            echo "tmsh modify ltm node $NODE_NAME session user-enabled"
          elif [[ "$NODE_SESSION" == "user-disabled" && "$NODE_STATE" == "user-down" ]]; then
            # Force Offline
            echo "tmsh modify ltm node $NODE_NAME state user-down session user-disabled"
          elif [[ "$NODE_SESSION" == "user-disabled" ]]; then
            # Disabled
            echo "tmsh modify ltm node $NODE_NAME session user-disabled"
          else
            # Everything else (monitor-enabled, default, etc.) => Enabled
            echo "tmsh modify ltm node $NODE_NAME session user-enabled"
          fi
        }

        # Walk through pool detail line by line to detect each member block
        while IFS= read -r line; do
          # New member block line, e.g.:
          #     app1_server_1:http {
          #     web-frontend-01:http {
          if [[ "$line" =~ ^[[:space:]]+[A-Za-z0-9_./-]+:[A-Za-z0-9_./-]+[[:space:]]*\{ ]]; then
            # Flush previous member (if any)
            if [[ -n "$CURRENT_MEMBER" ]]; then
              flush_member "$CURRENT_MEMBER" "$MEMBER_SESSION" "$MEMBER_STATE"
            fi

            CURRENT_MEMBER=$(echo "$line" | awk '{print $1}')
            MEMBER_SESSION=""
            MEMBER_STATE=""
            continue
          fi

          # Inside a member block: look for session/state lines
          if [[ -n "$CURRENT_MEMBER" ]]; then
            case "$line" in
              *"session "*)
                # e.g. "            session monitor-enabled"
                val=$(echo "$line" | awk '{print $2}')
                [[ -n "$val" ]] && MEMBER_SESSION="$val"
                ;;
              *"state "*)
                # e.g. "            state user-down"
                val=$(echo "$line" | awk '{print $2}')
                [[ -n "$val" ]] && MEMBER_STATE="$val"
                ;;
            esac
          fi
        done <<< "$POOL_DETAIL"

        # Flush last member after loop
        if [[ -n "$CURRENT_MEMBER" ]]; then
          flush_member "$CURRENT_MEMBER" "$MEMBER_SESSION" "$MEMBER_STATE"
        fi

      else
        echo "# No members found in pool $POOL_NAME (or cannot list pool members)"
      fi
    else
      echo "# No default pool attached to VS $VS"
    fi


    ###################################################
    # Network / self IP recreation (existing logic)
    ###################################################

    if [[ "$NET_ACTION" -eq 1 ]]; then
      # --- NON-floating self ---
      if [[ -n "$SELF_NON_FLOAT" ]]; then
        ADDR_NON_FLOAT=$(echo "$SELF_LINES" | \
          grep "self $SELF_NON_FLOAT " | \
          sed -n 's/.* address \([0-9.\/]*\) .*/\1/p' | head -1)

        if [[ -n "$ADDR_NON_FLOAT" ]]; then
          echo "tmsh create net self $SELF_NON_FLOAT address $ADDR_NON_FLOAT vlan $VLAN allow-service none traffic-group traffic-group-local-only"
        else
          echo "# ERROR: cannot extract address for $SELF_NON_FLOAT"
        fi
      else
        echo "# No non-floating self for vlan $VLAN"
      fi

      # --- FLOATING self ---
      if [[ -n "$SELF_FLOAT" ]]; then
        ADDR_FLOAT=$(echo "$SELF_LINES" | \
          grep "self $SELF_FLOAT " | \
          sed -n 's/.* address \([0-9.\/]*\) .*/\1/p' | head -1)

        if [[ -n "$ADDR_FLOAT" ]]; then
          echo "tmsh create net self $SELF_FLOAT address $ADDR_FLOAT vlan $VLAN traffic-group traffic-group-1 allow-service none"
        else
          echo "# ERROR: cannot extract address for $SELF_FLOAT"
        fi
      else
        echo "# No floating self for vlan $VLAN"
      fi
    else
      echo "# (network objects for VLAN $VLAN already created earlier)"
    fi

    echo
  } >> "$CREATE_FILE"



done < "$INPUT_FILE"


#######################################################
# Write vlan_list.csv
#######################################################

VLAN_LIST_FILE="vlan_list.csv"

echo "Vlan Name,Vlan ID" > "$VLAN_LIST_FILE"

for V in "${UNIQUE_VLANS[@]}"; do
  TAG=$(tmsh list net vlan "$V" one-line 2>/dev/null | \
        sed -n 's/.* tag \([0-9][0-9]*\) .*/\1/p')

  if [[ -n "$TAG" ]]; then
    echo "$V,$TAG" >> "$VLAN_LIST_FILE"
  else
    echo "$V,<no-tag-found>" >> "$VLAN_LIST_FILE"
  fi
done


echo "Generated: $VLAN_LIST_FILE"
echo "Generated: $VIP_ASM_FILE"
echo "Generated: $DELETE_FILE"
echo "Generated: $CREATE_FILE"