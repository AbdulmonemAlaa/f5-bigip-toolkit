#!/bin/bash
#===============================================================================
# f5_ucs_backup.sh                                                  v3 - FINAL
#
# BIG-IP UCS backup, transferred to a remote SFTP/SCP server.
# Validated end to end against SolarWinds SFTP/SCP Server on Windows.
#
# Author: Eng. Abdulmonem Alaa Aldeen
#
# Install:
#     /shared/scripts/f5_ucs_backup.sh        chmod 700, root:root
#     /shared/scripts/f5_ucs_backup.conf      chmod 600, settings live HERE
#     /shared/scripts/.f5backup.cred          chmod 600, password only
#
# Schedule:
#     0 1 * * * /shared/scripts/f5_ucs_backup.sh >/dev/null 2>&1
#
# Settings belong in the .conf file, NOT in this script. Editing values in
# here means they are lost every time the script is updated - which is a real
# way to silently start shipping backups to the wrong server.
#
# F5 refs: K13132 (UCS backup/restore) - K13418 (crontab archiving)
#          K4422/K4423 (UCS contents)  - K175 (file transfers)
#===============================================================================

# cron provides a minimal PATH. Set it explicitly or tmsh will not be found.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

#=============================== DEFAULTS ======================================
# Every value below can be overridden by f5_ucs_backup.conf. Treat these as
# fallbacks, not as the place to configure the tool.

AUTH_METHOD="password"     # "key" | "password"
                           #   key      -> Windows OpenSSH, Serv-U, Bitvise, Linux
                           #   password -> SolarWinds free SFTP/SCP Server, which
                           #               offers no public-key auth at all
TRANSFER="sftp"            # "sftp" | "scp"   (sftp is far more reliable here)

REMOTE_USER="f5backup"
REMOTE_HOST="192.0.2.10"
REMOTE_PORT="22"

# Path RELATIVE to the server's own root, never a C:\ path.
# SolarWinds presents its Root Directory as "/".
REMOTE_BASE="/"

REMOTE_MKDIR="yes"         # one subfolder per device, named after the hostname
REMOTE_VERIFY="yes"        # read the size back after upload and compare

LOCAL_DIR="/var/local/ucs" # leave this alone - the GUI reads only this path
LOCAL_KEEP_DAYS="7"

SSH_KEY="/root/.ssh/id_rsa"                 # AUTH_METHOD="key"
CRED_FILE="/shared/scripts/.f5backup.cred"  # AUTH_METHOD="password"
CONF_FILE="/shared/scripts/f5_ucs_backup.conf"
LOGFILE="/var/log/f5_ucs_backup.log"

EXPECT_TIMEOUT="300"       # seconds expect waits at each prompt. Raise it for
                           # very large archives over slow links.

UCS_PASSPHRASE=""          # set to encrypt the archive. Lose it and the
                           # archive is unrecoverable - store it in a vault.
                           # NOTE: passed on the tmsh command line, so it is
                           # briefly visible in `ps` - see README.
UCS_NO_PRIVATE_KEY="no"    # "yes" omits SSL private keys from the archive
#===============================================================================

#--------------------------- logging and exit ----------------------------------
# Defined before the conf is read, so that refusing to load an unsafe conf is
# still logged and still exits non-zero.
EXPECT_OUT=""
BATCH=""
LIST_OUT=""

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$$] $*" >> "${LOGFILE}"; }

cleanup() {
    [ -n "${EXPECT_OUT}" ] && rm -f "${EXPECT_OUT}"
    [ -n "${BATCH}" ]      && rm -f "${BATCH}"
    [ -n "${LIST_OUT}" ]   && rm -f "${LIST_OUT}"
    return 0
}

fail() {
    log "ERROR: $*"
    logger -p local0.err "f5_ucs_backup: FAILED - $*"
    cleanup
    exit 1
}

#--------------------------- load site settings --------------------------------
# The conf is sourced, so anyone who can write it can run commands as root.
# Refuse to read it unless only root can change it.
if [ -f "${CONF_FILE}" ]; then
    CONF_OWNER=$(stat -c %u "${CONF_FILE}" 2>/dev/null)
    CONF_MODE=$(stat -c %a "${CONF_FILE}" 2>/dev/null)

    [ -n "${CONF_OWNER}" ] && [ -n "${CONF_MODE}" ] \
        || fail "cannot stat ${CONF_FILE}"
    [ "${CONF_OWNER}" = "0" ] \
        || fail "${CONF_FILE} must be owned by root (uid 0) - found uid ${CONF_OWNER}. Run: chown root:root ${CONF_FILE}"
    [ $(( 8#${CONF_MODE} & 8#22 )) -eq 0 ] \
        || fail "${CONF_FILE} must not be group- or world-writable - found mode ${CONF_MODE}. Run: chmod 600 ${CONF_FILE}"

    . "${CONF_FILE}"
    CONF_USED="${CONF_FILE}"
else
    CONF_USED="built-in defaults (no ${CONF_FILE})"
fi

#--------------------------------- setup ---------------------------------------
HOSTNAME_SHORT="$(/bin/hostname -s)"   # bare `hostname` on BIG-IP is a TMOS
                                       # wrapper that prints a warning instead
STAMP="$(date +%Y-%m-%d_%H%M)"
UCS_NAME="${HOSTNAME_SHORT}-${STAMP}.ucs"
UCS_PATH="${LOCAL_DIR}/${UCS_NAME}"

# Strip a trailing slash so a root of "/" cannot produce "//name".
REMOTE_BASE="${REMOTE_BASE%/}"

if [ "${REMOTE_MKDIR}" = "yes" ]; then
    REMOTE_DIR="${REMOTE_BASE}/${HOSTNAME_SHORT}"
else
    REMOTE_DIR="${REMOTE_BASE}"
fi

COMMON_OPTS="-o StrictHostKeyChecking=yes -o ConnectTimeout=15"
PORT_OPT="-P ${REMOTE_PORT}"           # scp and sftp use -P
SSH_PORT_OPT="-p ${REMOTE_PORT}"       # ssh uses -p

# Unpredictable names, so no other local user can pre-create the transcript or
# read a password prompt out of a guessable path.
EXPECT_OUT=$(mktemp /var/tmp/f5_ucs_expect.XXXXXX) || fail "cannot create a temp file in /var/tmp"
BATCH=$(mktemp /var/tmp/f5_ucs_sftp.XXXXXX)        || fail "cannot create a temp file in /var/tmp"
chmod 600 "${EXPECT_OUT}" "${BATCH}"

log "=== run started (host=${HOSTNAME_SHORT} auth=${AUTH_METHOD} xfer=${TRANSFER} conf=${CONF_USED}) ==="

#--------------------------- 0. preconditions ----------------------------------
[ -d "${LOCAL_DIR}" ] || mkdir -p "${LOCAL_DIR}" || fail "cannot create ${LOCAL_DIR}"

case "${AUTH_METHOD}" in
    key)
        [ -f "${SSH_KEY}" ] || fail "ssh key ${SSH_KEY} not found"
        AUTH_OPTS="-i ${SSH_KEY} -o BatchMode=yes"
        ;;
    password)
        [ -x /usr/bin/expect ] || fail "/usr/bin/expect missing - password mode impossible"
        [ -f "${CRED_FILE}" ]  || fail "credential file ${CRED_FILE} not found"
        PERM=$(stat -c %a "${CRED_FILE}")
        [ "${PERM}" = "600" ] || fail "${CRED_FILE} must be chmod 600 (found ${PERM})"
        # A trailing \r - file touched on Windows, or a garbled paste - makes
        # the password silently wrong. Strip it.
        REMOTE_PASS=$(head -n1 "${CRED_FILE}" | tr -d '\r\n')
        [ -n "${REMOTE_PASS}" ] || fail "${CRED_FILE} is empty"
        AUTH_OPTS="-o PubkeyAuthentication=no -o PreferredAuthentications=password"
        ;;
    *)  fail "AUTH_METHOD must be 'key' or 'password' (got '${AUTH_METHOD}')" ;;
esac

case "${TRANSFER}" in
    sftp|scp) : ;;
    *) fail "TRANSFER must be 'sftp' or 'scp' (got '${TRANSFER}')" ;;
esac

VAR_USED=$(df -P /var | awk 'NR==2 {gsub("%","",$5); print $5}')
[ "${VAR_USED}" -ge 90 ] && log "WARNING: /var is ${VAR_USED}% full"

#--------------------------- expect driver -------------------------------------
# One expect program, used for the transfer and - in scp mode - again for the
# separate verification listing. Callers export F5BK_SPAWN and F5BK_CMDS first.
#
# The password travels by environment, never interpolated into the expect
# script: a password containing [ ] $ " or \ would otherwise be parsed as Tcl
# syntax and mangled. It is not in argv either, so `ps` cannot see it.
run_expect() {
    local out="$1"
    export F5BK_PASS="${REMOTE_PASS}"
    export F5BK_TIMEOUT="${EXPECT_TIMEOUT}"

    /usr/bin/expect > "${out}" 2>&1 <<'EXPECTEOF'
log_user 1
set timeout $env(F5BK_TIMEOUT)
set tries 0

spawn {*}$env(F5BK_SPAWN)

# Phase 1 - authenticate.
expect {
    -re "(?i)password:" {
        incr tries
        # A second prompt means the first password was rejected. Matching on
        # the word "denied" instead would misfire on a normal mkdir failure.
        if {$tries > 1} { exit 3 }
        send -- "$env(F5BK_PASS)\r"
        exp_continue
    }
    -re "(?i)connection refused"           { exit 4 }
    -re "(?i)no route to host"             { exit 5 }
    -re "(?i)host key verification failed" { exit 6 }
    -re "(?i)permission denied"            { exit 3 }
    -re "sftp>"                            { }
    timeout                                { exit 2 }
    eof                                    { }
}

# Phase 2 - for sftp, drive the session one command at a time.
if {[string length $env(F5BK_CMDS)] > 0} {
    foreach cmd [split $env(F5BK_CMDS) "\n"] {
        if {[string trim $cmd] eq ""} { continue }
        send -- "$cmd\r"
        expect {
            -re "sftp>" { }
            timeout     { exit 2 }
            eof         { }
        }
    }
    send -- "bye\r"
}

expect eof
catch wait result
exit [lindex $result 3]
EXPECTEOF
    local rc=$?
    unset F5BK_PASS
    return ${rc}
}

# Turn an expect exit code into a fatal error. $1 = rc, $2 = transcript path.
expect_rc_fail() {
    case "$1" in
        0) return 0 ;;
        2) fail "timed out talking to ${REMOTE_HOST}:${REMOTE_PORT}" ;;
        3) fail "password rejected for ${REMOTE_USER} - check ${CRED_FILE} (run 'cat -A' on it: a trailing ^M means CR contamination)" ;;
        4) fail "connection refused by ${REMOTE_HOST}:${REMOTE_PORT}" ;;
        5) fail "no route to ${REMOTE_HOST} - check REMOTE_HOST and routing" ;;
        6) fail "host key verification failed - connect once by hand to accept it" ;;
        *) fail "transfer failed (rc=$1): $(grep -v '^spawn ' "$2" | tr -d '\r' | tail -3 | tr '\n' ' ')" ;;
    esac
}

#--------------------------- 1. create the UCS ---------------------------------
UCS_ARGS=""
[ -n "${UCS_PASSPHRASE}" ]        && UCS_ARGS="${UCS_ARGS} passphrase ${UCS_PASSPHRASE}"
[ "${UCS_NO_PRIVATE_KEY}" = "yes" ] && UCS_ARGS="${UCS_ARGS} no-private-key"

tmsh save /sys ucs "${UCS_PATH}" ${UCS_ARGS} >> "${LOGFILE}" 2>&1 \
    || fail "tmsh save /sys ucs returned a non-zero exit code"

[ -s "${UCS_PATH}" ] || fail "UCS file ${UCS_PATH} missing or empty"
LOCAL_SIZE=$(stat -c %s "${UCS_PATH}")
log "UCS created: ${UCS_PATH} (${LOCAL_SIZE} bytes)"

#--------------------------- 2. transfer ---------------------------------------
if [ "${AUTH_METHOD}" = "key" ]; then
    # Key auth is non-interactive, so the sftp batch file is fine here.
    {
        [ "${REMOTE_MKDIR}" = "yes" ] && echo "-mkdir ${REMOTE_DIR}"
        echo "put ${UCS_PATH} ${REMOTE_DIR}/${UCS_NAME}"
        [ "${REMOTE_VERIFY}" = "yes" ] && [ "${TRANSFER}" = "sftp" ] \
            && echo "ls -l ${REMOTE_DIR}/${UCS_NAME}"
        echo "bye"
    } > "${BATCH}"

    if [ "${TRANSFER}" = "sftp" ]; then
        OUTPUT=$(sftp -b "${BATCH}" ${PORT_OPT} ${AUTH_OPTS} ${COMMON_OPTS} \
                 "${REMOTE_USER}@${REMOTE_HOST}" 2>&1) \
            || fail "sftp upload failed: $(echo "${OUTPUT}" | tail -3 | tr '\n' ' ')"
    else
        OUTPUT=$(scp ${PORT_OPT} ${AUTH_OPTS} ${COMMON_OPTS} "${UCS_PATH}" \
                 "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/${UCS_NAME}" 2>&1) \
            || fail "scp upload failed: $(echo "${OUTPUT}" | tail -3 | tr '\n' ' ')"
    fi

else
    #-------------------------------------------------------------------------
    # Password mode.
    #
    # "sftp -b" is deliberately NOT used. Whenever -b is given, sftp appends
    # "-obatchmode=yes" to the ssh command line, which suppresses the password
    # prompt entirely: expect waits for a prompt that never arrives and the
    # transfer dies with "Permission denied (password)". "-o BatchMode=no" does
    # not reliably override it. Driving an ordinary interactive session and
    # sending each command is what actually works - the same thing you do when
    # you run sftp by hand.
    #-------------------------------------------------------------------------
    if [ "${TRANSFER}" = "sftp" ]; then
        SPAWN_CMD="sftp ${PORT_OPT} ${AUTH_OPTS} ${COMMON_OPTS} ${REMOTE_USER}@${REMOTE_HOST}"
        CMDS=""
        [ "${REMOTE_MKDIR}" = "yes" ] && CMDS="${CMDS}mkdir ${REMOTE_DIR}
"
        CMDS="${CMDS}put ${UCS_PATH} ${REMOTE_DIR}/${UCS_NAME}
"
        [ "${REMOTE_VERIFY}" = "yes" ] && CMDS="${CMDS}ls -l ${REMOTE_DIR}/${UCS_NAME}
"
        export F5BK_CMDS="${CMDS}"
    else
        SPAWN_CMD="scp ${PORT_OPT} ${AUTH_OPTS} ${COMMON_OPTS} ${UCS_PATH} ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/${UCS_NAME}"
        export F5BK_CMDS=""
    fi
    export F5BK_SPAWN="${SPAWN_CMD}"

    run_expect "${EXPECT_OUT}"
    RC=$?
    expect_rc_fail "${RC}" "${EXPECT_OUT}"

    OUTPUT=$(cat "${EXPECT_OUT}")
fi

#--------------------------- 3. verify -----------------------------------------
# Pull the genuine `ls -l` line out of a transcript.
#
# This matters more than it looks. In password mode expect runs with log_user 1,
# so the transcript also echoes the commands we typed - "sftp> put .../NAME.ucs"
# and "sftp> ls -l .../NAME.ucs" - along with "Uploading ..." and the progress
# line. Every one of those contains the file name, so grepping the whole
# transcript for the name succeeds even when nothing was written. Only a line
# that begins with a Unix mode string is a real directory listing.
listing_line() {
    tr -d '\r' \
      | grep -F -- "${UCS_NAME}" \
      | grep -v 'sftp>' \
      | grep -v '^spawn ' \
      | grep -E '^[[:space:]]*[-dlbcps][-rwxSsTtLl]{9}[[:space:]]' \
      | head -n 1
}

# 0 = name and exact byte size confirmed
# 1 = no listing line at all
# 2 = listing found but the size does not match
# On success VERIFY_LINE holds the listing that was accepted.
verify_from() {
    VERIFY_LINE=$(printf '%s\n' "$1" | listing_line)
    [ -n "${VERIFY_LINE}" ] || return 1
    printf '%s\n' "${VERIFY_LINE}" \
        | grep -qE "(^|[^0-9])${LOCAL_SIZE}([^0-9]|\$)" || return 2
    return 0
}

verify_ok() {
    log "OK: ${REMOTE_HOST}:${REMOTE_DIR}/${UCS_NAME} verified (${LOCAL_SIZE} bytes)"
    logger -p local0.notice "f5_ucs_backup: OK ${UCS_NAME} -> ${REMOTE_HOST}"
}

sent_unverified() {
    log "SENT (unverified): ${REMOTE_HOST}:${REMOTE_DIR}/${UCS_NAME} (${LOCAL_SIZE} bytes)"
    logger -p local0.notice "f5_ucs_backup: sent ${UCS_NAME} - $1"
}

if [ "${REMOTE_VERIFY}" != "yes" ]; then
    log "SENT (verification disabled by REMOTE_VERIFY): ${REMOTE_HOST}:${REMOTE_DIR}/${UCS_NAME} (${LOCAL_SIZE} bytes)"
    logger -p local0.notice "f5_ucs_backup: sent ${UCS_NAME}"

elif [ "${TRANSFER}" = "sftp" ]; then
    # The listing came back in the same session as the upload.
    verify_from "${OUTPUT}"
    case $? in
        0) verify_ok ;;
        1) fail "upload NOT confirmed - no directory listing for ${UCS_NAME} came back from ${REMOTE_HOST}. The file may never have been written." ;;
        2) fail "size mismatch for ${UCS_NAME}: expected ${LOCAL_SIZE} bytes, remote listing was: ${VERIFY_LINE}" ;;
    esac

else
    #-------------------------------------------------------------------------
    # scp mode. scp moves the file and says nothing else, so ${OUTPUT} holds no
    # listing to read. Ask the server separately over ssh.
    #
    # scp is normally chosen precisely because sftp is disabled on the server,
    # so a listing is not guaranteed to be obtainable. If one cannot be
    # fetched, say so plainly and fall back on scp's own exit status, which is
    # already non-zero on a failed transfer. If a listing IS returned, it is
    # enforced strictly.
    #-------------------------------------------------------------------------
    LIST_OUT=$(mktemp /var/tmp/f5_ucs_list.XXXXXX) || fail "cannot create a temp file in /var/tmp"
    chmod 600 "${LIST_OUT}"
    LIST_CMD="ls -l ${REMOTE_DIR}/${UCS_NAME}"

    if [ "${AUTH_METHOD}" = "key" ]; then
        ssh ${SSH_PORT_OPT} ${AUTH_OPTS} ${COMMON_OPTS} \
            "${REMOTE_USER}@${REMOTE_HOST}" "${LIST_CMD}" > "${LIST_OUT}" 2>&1
        LIST_RC=$?
    else
        export F5BK_SPAWN="ssh ${SSH_PORT_OPT} ${AUTH_OPTS} ${COMMON_OPTS} ${REMOTE_USER}@${REMOTE_HOST} ${LIST_CMD}"
        export F5BK_CMDS=""
        run_expect "${LIST_OUT}"
        LIST_RC=$?
    fi

    # A definitive "it is not there" outranks everything else. This is the case
    # the old code could not see at all.
    if grep -qiE "no such file|not found|cannot access|does not exist" "${LIST_OUT}"; then
        fail "upload NOT confirmed - ${REMOTE_HOST} reports that ${REMOTE_DIR}/${UCS_NAME} does not exist"
    fi

    verify_from "$(cat "${LIST_OUT}")"
    case $? in
        0) verify_ok ;;
        2) fail "size mismatch for ${UCS_NAME}: expected ${LOCAL_SIZE} bytes, remote listing was: ${VERIFY_LINE}" ;;
        1) # No listing came back and the server did not say the file is absent.
           # scp is normally chosen because sftp/exec is unavailable, so treat
           # this as inconclusive rather than as a failure: scp's own exit
           # status already reported the transfer as successful.
           if [ "${LIST_RC}" -ne 0 ]; then
               log "NOTE: verification skipped - could not list ${REMOTE_DIR}/${UCS_NAME} over ssh (rc=${LIST_RC}). scp itself reported success, which confirms the transfer completed. Use TRANSFER=\"sftp\" for a size-verified upload, or set REMOTE_VERIFY=\"no\" to silence this."
           else
               log "NOTE: verification skipped - the server answered the listing request but returned nothing resembling an 'ls -l' line. scp itself reported success."
           fi
           sent_unverified "listing unavailable" ;;
    esac
fi

cleanup

#--------------------------- 4. local retention --------------------------------
# The pattern is anchored to this host's name, so pre-existing archives such as
# config.ucs or <name>.BeforeUpgrade.ucs are never touched.
DELETED=$(find "${LOCAL_DIR}" -maxdepth 1 -name "${HOSTNAME_SHORT}-*.ucs" \
          -type f -mtime +${LOCAL_KEEP_DAYS} -print -delete | wc -l)
log "local retention: removed ${DELETED} archive(s) older than ${LOCAL_KEEP_DAYS} days"

log "=== run finished ==="
exit 0
