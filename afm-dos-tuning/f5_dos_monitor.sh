#!/bin/bash

#######################################################
# f5_dos_monitor.sh
#######################################################
#
# Author:
#   Eng. Abdulmonem Alaa Aldeen
#
# Purpose:
#   Continuously monitor F5 BIG-IP DoS device configuration
#   using:
#       tmsh show security dos device-config
#
#   The script:
#     - Executes every 10 minutes
#     - Logs output per-day under /var/tmp/YYYY-MM-DD/
#     - Detects end-of-day (23:50+)
#     - Waits for midnight safely
#     - Automatically continues next day
#
#   Includes:
#     - Debug logging
#     - PID tracking, with a single-instance guard: the script refuses to
#       start while another copy is running, and clears a stale PID file
#     - Safe midnight rollover handling
#
# Usage:
#
#   1) Copy onto the BIG-IP, convert & make executable (first time only):
#        cp f5_dos_monitor.sh /var/tmp/
#        sed -i 's/\r$//' /var/tmp/f5_dos_monitor.sh
#        chmod +x /var/tmp/f5_dos_monitor.sh
#
#   2) Stop old running instances (if upgrading):
#        pkill -9 -f f5_dos_monitor.sh
#        rm -f /var/tmp/f5_dos_monitor.pid
#        rm -f /var/tmp/f5_monitor_debug.log
#
#   3) Start new version in background:
#        nohup /var/tmp/f5_dos_monitor.sh > /dev/null 2>&1 &
#
#   4) Verify script is running:
#        ps aux | grep f5_dos_monitor | grep -v grep
#
#   5) Monitor debug log in real-time:
#        tail -f /var/tmp/f5_monitor_debug.log
#
#   6) To stop the script manually:
#        pkill -9 -f f5_dos_monitor.sh
#
# Outputs:
#   - /var/tmp/YYYY-MM-DD/tmsh_dos_monitor.log
#   - /var/tmp/f5_monitor_debug.log
#   - /var/tmp/f5_dos_monitor.pid
#
#######################################################


#######################################################
# Configuration
#######################################################

SCRIPT_PID_FILE="/var/tmp/f5_dos_monitor.pid"
DEBUG_LOG="/var/tmp/f5_monitor_debug.log"

# Used by the single-instance check below, so a renamed copy still works.
SCRIPT_NAME="$(basename "$0")"


#######################################################
# PID Handling
#######################################################

# Is the PID recorded in the PID file a live instance of this script?
is_running() {
    local pid="$1"

    [ -z "$pid" ] && return 1
    kill -0 "$pid" 2>/dev/null || return 1

    # Guard against PID reuse: when /proc is readable, confirm the process
    # really is this script. When it is not readable, assume it is (safer).
    if [ -r "/proc/$pid/cmdline" ]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" | grep -qF "$SCRIPT_NAME"
        return $?
    fi

    return 0
}

# Refuse to start a second instance: two loops appending to the same daily
# log produce duplicate samples and skew any tuning based on them.
if [ -f "$SCRIPT_PID_FILE" ]; then
    OLD_PID=$(tr -d ' \t\r\n' < "$SCRIPT_PID_FILE" 2>/dev/null)

    if is_running "$OLD_PID"; then
        echo "ERROR: f5_dos_monitor.sh is already running (PID $OLD_PID)." >&2
        echo "       To replace it:" >&2
        echo "         pkill -9 -f f5_dos_monitor.sh" >&2
        echo "         rm -f $SCRIPT_PID_FILE" >&2
        exit 1
    fi

    echo "Note: removing stale PID file (PID $OLD_PID is not running)." >&2
fi

# Save PID for external monitoring/control
echo $$ > "$SCRIPT_PID_FILE"

# Remove the PID file on exit. TERM and INT must exit explicitly: a trap
# handler on its own just returns, and the monitoring loop would carry on
# without a PID file. A kill -9 cannot be trapped at all, which is why the
# stale-PID check above exists.
trap 'rm -f "$SCRIPT_PID_FILE"' EXIT
trap 'rm -f "$SCRIPT_PID_FILE"; exit 143' TERM
trap 'rm -f "$SCRIPT_PID_FILE"; exit 130' INT


#######################################################
# Logging Functions
#######################################################

# Debug logging function
debug() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $1" >> "$DEBUG_LOG"
}

# Standard log function (per-day directory)
log_message() {
    DATE_DIR="/var/tmp/$(date '+%Y-%m-%d')"
    LOG_FILE="${DATE_DIR}/tmsh_dos_monitor.log"
    mkdir -p "$DATE_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    debug "$1"
}


#######################################################
# TMSH Execution Function
#######################################################

run_tmsh() {
    DATE_DIR="/var/tmp/$(date '+%Y-%m-%d')"
    LOG_FILE="${DATE_DIR}/tmsh_dos_monitor.log"
    mkdir -p "$DATE_DIR"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== TMSH Command =====" >> "$LOG_FILE"
    tmsh show security dos device-config >> "$LOG_FILE" 2>&1
    local exit_code=$?
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Command completed (exit code: $exit_code)" >> "$LOG_FILE"
    echo "----------------------------------------" >> "$LOG_FILE"

    debug "tmsh command executed with exit code: $exit_code"
}


#######################################################
# Initial Execution
#######################################################

debug "=== MONITOR STARTED (PID: $$) ==="
log_message "=== MONITOR STARTED (PID: $$) ==="

# Run initial command immediately
run_tmsh


#######################################################
# Main Monitoring Loop
#######################################################

while true; do

    ###################################################
    # Time Calculation
    ###################################################

    HOUR=$(date '+%H')
    MINUTE=$(date '+%M')

    HOUR=$((10#$HOUR))
    MINUTE=$((10#$MINUTE))
    TOTAL_MINUTES=$((HOUR * 60 + MINUTE))


    ###################################################
    # End-of-Day Handling (23:50+)
    ###################################################

    if [ $TOTAL_MINUTES -ge 1430 ]; then

        log_message "End of day reached at $(date '+%H:%M'). Waiting for midnight..."

        # Final execution before midnight
        run_tmsh

        CURRENT_DAY=$(date '+%Y-%m-%d')

        # Wait until day changes
        while [ "$CURRENT_DAY" == "$(date '+%Y-%m-%d')" ]; do
            sleep 60
        done

        NEW_DAY=$(date '+%Y-%m-%d')
        log_message "New day started: $NEW_DAY"

        # Run at start of new day
        run_tmsh

        continue
    fi


    ###################################################
    # 10-Minute Sleep Cycle (1-Minute Granularity)
    ###################################################

    log_message "Next run in 10 minutes"

    for i in {1..10}; do
        sleep 60

        HOUR=$(date '+%H')
        MINUTE=$(date '+%M')
        HOUR=$((10#$HOUR))
        MINUTE=$((10#$MINUTE))
        TOTAL_MINUTES=$((HOUR * 60 + MINUTE))

        # Re-check end-of-day during sleep
        if [ $TOTAL_MINUTES -ge 1430 ]; then

            log_message "Reached end of day during sleep at $HOUR:$MINUTE"

            run_tmsh

            CURRENT_DAY=$(date '+%Y-%m-%d')

            while [ "$CURRENT_DAY" == "$(date '+%Y-%m-%d')" ]; do
                sleep 60
            done

            NEW_DAY=$(date '+%Y-%m-%d')
            log_message "New day started: $NEW_DAY"

            run_tmsh

            continue 2
        fi
    done


    ###################################################
    # Normal Scheduled Execution
    ###################################################

    run_tmsh
done