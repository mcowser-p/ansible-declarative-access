# Logs, viewing them, and log rotation

*Audience: college-freshman level and up. Shared reference for every service —
the web servers ([httpd](httpd.md), [nginx](nginx.md), [Tomcat](tomcat.md)) and
the databases ([MySQL](mysql.md), [PostgreSQL](postgresql.md)). Every "what
gets created" fact comes from the real packages on AlmaLinux 9.*

## Two places logs go

On a modern EL server, a service's output ends up in one (or both) of two
places:

1. **The systemd journal (journald).** systemd captures everything a service
   prints to its output streams — startup messages, crashes, warnings — into a
   central binary journal. You read it with **`journalctl`**. This is where you
   look first for "did the service start? why did it die?"
2. **The application's own log files** under `/var/log/<app>/`. Web servers and
   databases write detailed **access** and **error** logs themselves, as plain
   text files, because they log far more traffic than belongs in the journal.

Rule of thumb: **`journalctl` for the service's health; the log files for the
application's detail.** For most apps you'll use both.

## Reading the journal with journalctl

```bash
sudo journalctl -u httpd            # all journal entries for the httpd unit
sudo journalctl -u httpd -e         # jump to the newest entries
sudo journalctl -u httpd -ef        # follow live (like tail -f); Ctrl-C to stop
sudo journalctl -u httpd --since -15m   # the last 15 minutes
sudo journalctl -u httpd -p err     # only error-priority and worse
sudo journalctl -u httpd -b         # only since the last boot
```

Why `sudo`? System-service journals are readable only by root or members of
the `systemd-journal`/`adm` groups. Under restricted access your profile grants
the specific `sudo journalctl -u <service>` forms, which is how a team reads
its own service's journal.

> **Persistent vs. volatile journal.** If `/var/log/journal/` exists, the
> journal survives reboots; otherwise it lives in RAM (`/run/log/journal`) and
> is lost on reboot. Make it persistent with `sudo mkdir -p /var/log/journal &&
> sudo systemctl restart systemd-journald` (or `Storage=persistent` in
> `/etc/systemd/journald.conf`).

> **You do NOT log-rotate the journal.** journald manages its own size — it caps
> disk use itself (`SystemMaxUse=`, `MaxRetentionSec=` in `journald.conf`).
> logrotate is only for the plain-text files under `/var/log/<app>/`.

## Reading application log files

```bash
sudo tail -f /var/log/nginx/error.log        # follow the newest lines live
sudo less /var/log/httpd/access_log          # page through (q to quit)
sudo grep -i 'error' /var/log/mysql/mysqld.log
```

Under restricted access, your profile's `folders_read` grant (an ACL on
`/var/log/<app>/`) lets the team read these without `sudo`.

## How log rotation works

Left alone, a busy `access.log` would grow until it fills the disk.
**logrotate** prevents that: once a day it renames the current log aside,
starts a fresh one, keeps a few old copies (usually compressed), and deletes
the oldest.

On EL9 logrotate runs from a systemd timer — **`logrotate.timer` →
`logrotate.service`**, daily. (That is the very timer you saw nginx's install
pull in.) It reads `/etc/logrotate.conf` for global defaults, then every file
in **`/etc/logrotate.d/`** — one fragment per application. A typical fragment:

```
/var/log/nginx/*.log {
    daily              # rotate once a day
    rotate 10          # keep 10 old files
    compress           # gzip the old ones
    delaycompress      # ...but not the most recent (still being read)
    missingok          # don't error if the log is absent
    notifempty         # skip rotation if the log is empty
    create 0640 nginx root   # recreate the fresh log with these perms
    postrotate               # after rotating, tell the app to reopen its files
        /bin/kill -USR1 `cat /run/nginx.pid` ...
    endscript
}
```

**The one subtlety: reopening the file.** After logrotate renames `access.log`
to `access.log.1`, the running service is still writing to the *old* file (by
its open handle). The fragment must tell the service to reopen — two ways:

- **Signal / reload** (`postrotate ... kill -USR1` or `systemctl reload`): the
  service closes and reopens its logs cleanly. Preferred. Used by nginx and
  httpd.
- **`copytruncate`**: logrotate copies the file aside then truncates the
  original in place, so the service's handle keeps working. Used when a service
  *can't* be signalled to reopen (e.g. Tomcat's `catalina.out`). Small risk of
  losing a few lines written during the copy.

## What each service ships — the quick table

| Service | Writes files to | journald too? | Ships a logrotate fragment? | Rotation trigger |
|---|---|---|---|---|
| [httpd](httpd.md) | `/var/log/httpd/{access,error}_log` | lifecycle only | ✅ active `/etc/logrotate.d/httpd` | `systemctl reload httpd` |
| [nginx](nginx.md) | `/var/log/nginx/{access,error}.log` | lifecycle only | ✅ active `/etc/logrotate.d/nginx` | `kill -USR1` |
| [Tomcat](tomcat.md) | `/var/log/tomcat/catalina.out` + dated logs | lifecycle only | ⚠️ ships **`.disabled`** | `copytruncate` (once enabled) |
| [MySQL](mysql.md) | `/var/log/mysql/mysqld.log` | lifecycle only | ⚠️ ships **commented-out** | `kill -USR1` (once enabled) |
| [PostgreSQL](postgresql.md) | `/var/lib/pgsql/data/log/*.log` | if configured | ❌ none — **self-rotates** | built-in collector |

Two of these need action (Tomcat and MySQL ship rotation *disabled*), and
PostgreSQL rotates itself with no logrotate at all. The per-service guides cover
each.

## Logs and log rotation under restricted access

Once a team is in the **restricted admin** group
([the lifecycle](../application-deployment-lifecycle.md)):

- **Viewing the journal** — `sudo journalctl -u <service>` (and its `-e`/`-ef`/
  `--since` variants) is granted by the profile. Match the exact granted form
  (argument order matters — see any app guide's "exact-command gotcha").
- **Reading the log files** — granted, via the `folders_read` ACL on
  `/var/log/<app>/` in the profile.
- **Editing the rotation policy** — the fragment lives in
  **`/etc/logrotate.d/<app>`**, which is *outside* the app's own config tree
  (`/etc/<app>`), so the generated profile does **not** grant write to it by
  default. Changing rotation is normally a platform-team task. If a team must
  own it, add the one path explicitly at review time, e.g.:

  ```yaml
  declarative_access_files_modify:
    - /etc/logrotate.d/nginx
  ```

  (PostgreSQL is the exception — its rotation is configured in
  `postgresql.conf` *inside* `/var/lib/pgsql`, which the profile already
  grants.)

## Quick reference

```bash
# service health / why it died
sudo journalctl -u <service> -e
# follow a service live
sudo journalctl -u <service> -ef
# the app's own detailed logs
sudo tail -f /var/log/<app>/error.log
# check a logrotate fragment
cat /etc/logrotate.d/<app>
# dry-run what logrotate would do right now (safe, changes nothing)
sudo logrotate -d /etc/logrotate.d/<app>
# force a rotation now (for testing)
sudo logrotate -f /etc/logrotate.d/<app>
```
