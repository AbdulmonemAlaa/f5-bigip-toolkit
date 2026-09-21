# backup/

Scheduled UCS backup for BIG-IP: save the archive locally, push it to an SFTP or
SCP server, prove it arrived intact, then prune old local copies.

Written against SolarWinds' free SFTP/SCP Server on Windows, which offers no
public-key authentication at all — hence the password path. It works equally
well against Windows OpenSSH, Serv-U, Bitvise and Linux OpenSSH using a key.

| File | Purpose |
| --- | --- |
| `f5_ucs_backup.sh` | The tool. Runs from cron on the BIG-IP. |
| `f5_ucs_backup.conf.example` | Template. Copy to `f5_ucs_backup.conf` and edit. |

## Install

Copy both files onto the device and set ownership and permissions:

```bash
mkdir -p /shared/scripts
cp f5_ucs_backup.sh          /shared/scripts/
cp f5_ucs_backup.conf.example /shared/scripts/f5_ucs_backup.conf

chown root:root /shared/scripts/f5_ucs_backup.sh /shared/scripts/f5_ucs_backup.conf
chmod 700 /shared/scripts/f5_ucs_backup.sh
chmod 600 /shared/scripts/f5_ucs_backup.conf
```

| Path | Mode | Owner | Notes |
| --- | --- | --- | --- |
| `/shared/scripts/f5_ucs_backup.sh` | `700` | `root:root` | the script |
| `/shared/scripts/f5_ucs_backup.conf` | `600` | `root:root` | all site settings |
| `/shared/scripts/.f5backup.cred` | `600` | `root:root` | password only, password mode |
| `/var/local/ucs/` | — | — | where the archives land |
| `/var/log/f5_ucs_backup.log` | — | — | run log |

The script **refuses to run** if `f5_ucs_backup.conf` is not owned by `root` or
is group- or world-writable. The conf is sourced by a root process, so anyone
who can write it can run commands as root — the check is not cosmetic.

`/shared/` survives a software upgrade on BIG-IP; `/var/tmp` does not. Keep the
script and its config under `/shared/scripts`.

## Configure

Edit `/shared/scripts/f5_ucs_backup.conf`. Settings belong there, never in the
script — an updated script would silently reset them, which is a real way to
start shipping backups to the wrong server.

| Setting | Meaning |
| --- | --- |
| `AUTH_METHOD` | `key` or `password` |
| `TRANSFER` | `sftp` (recommended) or `scp` |
| `REMOTE_USER` / `REMOTE_HOST` / `REMOTE_PORT` | destination |
| `REMOTE_BASE` | path **relative to the server's own root**, never `C:\...` |
| `REMOTE_MKDIR` | `yes` gives each device its own subfolder, named after its hostname |
| `REMOTE_VERIFY` | `yes` reads the size back after upload |
| `LOCAL_DIR` | leave as `/var/local/ucs` — the GUI reads only that path |
| `LOCAL_KEEP_DAYS` | local retention, in days |
| `SSH_KEY` / `CRED_FILE` | credential locations |
| `EXPECT_TIMEOUT` | seconds expect waits at each prompt (default `300`) |

Take `REMOTE_BASE` from `pwd` inside an interactive `sftp` session, not from the
server's Windows folder path. SolarWinds reports `/`.

## Authentication

### Key (preferred)

```bash
ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa
ssh-copy-id -i /root/.ssh/id_rsa.pub f5backup@<server>
```

Set `AUTH_METHOD="key"`. The transfer is then fully non-interactive and `expect`
is not used at all.

### Password

For servers with no public-key support. Put the password — and nothing else — in
the credential file:

```bash
printf '%s' 'ThePassword' > /shared/scripts/.f5backup.cred
chmod 600 /shared/scripts/.f5backup.cred
```

Set `AUTH_METHOD="password"`. `/usr/bin/expect` must be present.

The script strips a trailing `\r`, because a file edited on Windows carries one
and makes the password silently wrong. If authentication fails, run
`cat -A /shared/scripts/.f5backup.cred` — a trailing `^M` is the giveaway.

The password is passed to `expect` through the environment, never interpolated
into the script and never in `argv`, so `ps` cannot see it and a password
containing `[ ] $ " \` is not mangled by Tcl.

## First run

Run it by hand before trusting cron:

```bash
/shared/scripts/f5_ucs_backup.sh; echo "exit=$?"
tail -20 /var/log/f5_ucs_backup.log
```

Connect once interactively first (`sftp f5backup@<server>`) so the host key is
accepted — `StrictHostKeyChecking=yes` is deliberate, and an unknown host key is
a hard failure rather than a silent trust-on-first-use.

## Schedule

```bash
crontab -e
0 1 * * * /shared/scripts/f5_ucs_backup.sh >/dev/null 2>&1
```

The script logs to its own file and to syslog (`local0`), so discarding cron's
output loses nothing. On BIG-IP, `crontab` edits are preserved across upgrades
per K13418.

## Verification

With `REMOTE_VERIFY="yes"` the script does not accept "the command ran" as proof.

- **sftp** — an `ls -l` runs in the same session as the upload. The script looks
  for a genuine listing line, one beginning with a Unix mode string, and
  requires the exact byte count to appear in it. A missing listing or a
  mismatched size is a **failure with a non-zero exit**, not a warning.
- **scp** — scp reports nothing but its exit status, so the script asks the
  server separately over ssh. If the server answers that the file is not there,
  that is a failure. If a listing comes back, the size is enforced. If no
  listing can be obtained — common, since scp is usually chosen precisely
  because sftp is disabled — the script says so in the log and relies on scp's
  own exit status.

Only a verified run logs `OK:`. Anything unverified says so explicitly.

> The transcript in password mode echoes the commands that were typed, so the
> file name appears in it whether or not anything was uploaded. Matching the
> name anywhere in the transcript is therefore meaningless — only the real
> listing line counts. This is why an earlier version of this script could
> report success after a failed upload.

## Retention

Local archives matching `<hostname>-*.ucs` older than `LOCAL_KEEP_DAYS` are
deleted after a successful run. The pattern is anchored to the device hostname,
so pre-existing archives such as `config.ucs` or `<name>.BeforeUpgrade.ucs` are
never touched. **Remote retention is the server's job** — this script never
deletes anything on the far end.

## Encryption

Setting `UCS_PASSPHRASE` encrypts the archive.

> ⚠️ The passphrase is passed on the `tmsh` command line, so it is briefly
> visible to anyone able to run `ps` on the device during the save. On a
> single-admin appliance that is usually acceptable; where it is not, leave
> `UCS_PASSPHRASE` empty and rely on encryption at rest on the backup server.

Lose the passphrase and the archive cannot be restored. Store it in a vault, not
in this repo and not only in the conf file.

## Exit codes

`0` success (verified, or explicitly unverified with a logged reason) — any
non-zero value means the backup did not complete. Failures are logged to
`/var/log/f5_ucs_backup.log` and to syslog as `local0.err`, so they can be
alerted on.

Common causes, all reported with a specific message: credential file missing or
not `600`, `expect` missing, host key not accepted, password rejected,
connection refused, no route, `tmsh save` failure, and upload not confirmed.

## Files this repo ignores

`f5_ucs_backup.conf`, `.f5backup.cred` and `*.ucs` are git-ignored — they hold a
real hostname, a password, and a complete copy of the device configuration.
Only `f5_ucs_backup.conf.example` is committed.

## References

F5 K13132 (UCS backup/restore), K13418 (crontab archiving), K4422 / K4423 (UCS
contents), K175 (file transfers).
