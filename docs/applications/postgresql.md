# PostgreSQL — an advanced relational database server

*Audience: college-freshman level and up. Every "what the install creates"
fact comes from a real treadmark footprint of `dnf install postgresql-server` on
AlmaLinux 9 (PostgreSQL 13) — not from memory.*

## What is it?

**PostgreSQL** ("post-gres") is a powerful open-source relational database,
like MySQL but with a reputation for strict correctness and advanced features
(rich data types, strong transactions, extensibility). Applications connect
over the network (default port **5432**) or a local socket and query it with
SQL. Like any database, it listens for your *application*, not the public
internet.

PostgreSQL has one setup step that surprises newcomers: **after installing, it
will not start until you initialize its database cluster.** That's the first
thing §3 covers.

## Quick facts

| Thing | Value |
|---|---|
| Package | `postgresql-server` (EL9: 13, streams to 15/16; EL10: 16) |
| Service unit | `postgresql.service` |
| Service account | `postgres` (uid 26) — **has a real shell**; admin runs as this user |
| Data + config directory | `/var/lib/pgsql/data/` (**config lives here, not `/etc`**) |
| Main config | `/var/lib/pgsql/data/postgresql.conf` |
| Client auth config | `/var/lib/pgsql/data/pg_hba.conf` (security-critical) |
| Logs | `/var/lib/pgsql/data/log/` |
| Port | 5432 |

## 1. Installing (during your setup window)

```bash
sudo dnf install postgresql-server
# NOTE: do not `enable --now` yet — the cluster doesn't exist. See §3.
```

## 2. What the install actually sets up

A **lean install — 354 files added** (much smaller than MySQL). The parts that
matter:

**A service account with a shell.** The `postgres` user (uid/gid 26) — and
unlike every other service in these guides, its shell is **`/bin/bash`, not
`nologin`**. That's deliberate: the traditional way to administer PostgreSQL
is to *become* the `postgres` user (`sudo -u postgres psql`), so it needs a
usable shell. `postgresql.service` runs as `User=postgres`.

**Directories:**

| Path | Purpose | Ownership |
|---|---|---|
| `/var/lib/pgsql/` | Everything Postgres owns | `postgres:postgres 0700` |
| `/var/lib/pgsql/data/` | The cluster: data + **config files** | postgres (created by initdb) |
| `/var/lib/pgsql/backups/` | Backup staging | postgres |
| `/etc/postgresql-setup/` | initdb helper config | root |

Note what's **not** there: no `/etc/postgresql`. PostgreSQL keeps its config
files *inside the data directory* (`postgresql.conf`, `pg_hba.conf`) — unusual,
and important to know when you go looking for them.

**One finding to understand** (from `risks[]`):

> **The install modifies the PAM stack: `/etc/pam.d/postgresql`.** The RPM
> drops this file so PostgreSQL can optionally authenticate database users
> against the system via PAM. It is expected for this package — but "PAM was
> modified" is always worth a reviewer's glance, and the footprint flags it so
> the decision is explicit, not silent.

## 3. Setting it up properly

**Step 1 — initialize the cluster (the step people miss).** A fresh install
has an *empty* data directory; `initdb` creates the actual database cluster.
This was verified live — it creates `PG_VERSION`, the `base/` and `global/`
directories, and the config files:

```bash
sudo postgresql-setup --initdb       # creates /var/lib/pgsql/data/*
sudo systemctl enable --now postgresql
systemctl status postgresql          # NOW it starts
```

**Step 2 — client authentication (`pg_hba.conf`).** This file decides *who may
connect and how* — it is the most security-critical file PostgreSQL has. It's
read top to bottom; the first matching line wins:

```bash
sudo -u postgres vi /var/lib/pgsql/data/pg_hba.conf
# Example line — require an encrypted password for local network connections:
#   host    appdb    appuser    127.0.0.1/32    scram-sha-256
sudo systemctl reload postgresql     # reload re-reads pg_hba.conf (no restart)
```

**Step 3 — server settings (`postgresql.conf`).** Listening address, port,
memory. Changing `listen_addresses` needs a restart; most other settings
reload.

**Step 4 — create the app's role and database** (never let the app use the
superuser):

```bash
sudo -u postgres createuser --pwprompt appuser
sudo -u postgres createdb --owner appuser appdb
```

**SELinux:** the default data directory is labeled correctly. If you move the
data directory elsewhere you must relabel it (`semanage fcontext` +
`restorecon`), or PostgreSQL won't start.

## 4. Administering the service

| Task | Command |
|---|---|
| Start / stop | `sudo systemctl start postgresql` / `stop postgresql` |
| Reload config (`pg_hba.conf`, most settings) | `sudo systemctl reload postgresql` |
| Restart (e.g. after `listen_addresses`) | `sudo systemctl restart postgresql` |
| Start at boot / not | `sudo systemctl enable postgresql` / `disable postgresql` |
| Is it running? | `systemctl status postgresql` |
| Service logs | `sudo journalctl -u postgresql` |
| Database logs | `/var/lib/pgsql/data/log/` |
| Open a SQL shell | `sudo -u postgres psql` |
| Back up a database | `sudo -u postgres pg_dump appdb > appdb.sql` |

**PostgreSQL *does* support graceful `reload`** (unlike MySQL): it re-reads
`pg_hba.conf` and most of `postgresql.conf` without dropping connections. Only
a few settings (listening address/port, shared memory) need a full `restart`.

> **Exact-command gotcha (once restricted):** granted journalctl forms are
> `journalctl -u postgresql`, `-e -u postgresql`, `-ef -u postgresql`,
> `--since -5m -u postgresql` (+`-10m`/`-15m`). `sudo -l` shows the exact list.

## 5. Encrypting connections (TLS)

Turn on TLS with `ssl = on` in `postgresql.conf`, place `server.crt` and
`server.key` in the data directory (the key **must** be `0600 postgres:postgres`
or Postgres refuses to start), and use `hostssl` lines in `pg_hba.conf` to
*require* encryption for chosen connections. Details in
**[TLS/SSL administration](tls-ssl.md#databases-encrypt-the-connection)**.

## 6. The access lifecycle: before & after

Standard [application deployment lifecycle](../application-deployment-lifecycle.md).

**Before — setup window (app admin):** full admin. `initdb`, edit
`pg_hba.conf` / `postgresql.conf`, create the app role and database.

**Capture & review:** the reviewer keeps the profile small and, like MySQL,
**config-scoped — no `postgres` group membership**
([examples/postgresql-access.yml](../../examples/postgresql-access.yml)). The
`postgres` group owns the raw cluster and DB admin is via `psql`, so instead of
granting the whole data dir the reviewer grants an **ACL on just the two config
files** (`postgresql.conf`, `pg_hba.conf`) plus **read on `data/log`**; the
role sets traverse ACLs on the parent data dir automatically, so raw data files
stay unreadable. `services: [postgresql]`, vendor unit ACLs dropped,
`postgres:postgres 0700` ownership preserved. The group option is available the
same way as MySQL's
(`-e enable_pam_group=true -e '{"declarative_access_local_groups":["postgres"]}'`;
see [File access: pam_group and ACLs](../declarative-systemd-access.md#file-access-pam_group-and-acls)).
Applied to `<hostname>-app_restricted`.

**After — restricted admin.** Verified end to end against a real PostgreSQL:

| ✓ Still yours | ✕ Gone |
|---|---|
| `sudo systemctl start/stop/restart/reload/status postgresql` | `sudo systemctl restart sshd` |
| `sudo journalctl -u postgresql` (+ variants) | `sudo dnf install …` |
| edit `postgresql.conf` / `pg_hba.conf` in the data dir (ACL) | edit vendor unit files |
| read `/var/lib/pgsql/data/log/*` (ACL) | anything not PostgreSQL |
| `sudo -u postgres psql` (DB-level admin) | — |

## Logs & log rotation

See [logging.md](logging.md) for the shared concepts. PostgreSQL is the odd one
out — it does **not** use system logrotate.

**What gets created.** When the built-in **logging collector** is on, PostgreSQL
writes to **`/var/lib/pgsql/data/log/`** — typically `postgresql-<dow>.log`
(one file per day of the week). If the collector is off, it logs to stderr,
which systemd captures into the **journal** instead.

**How to view:**
```bash
sudo tail -f /var/lib/pgsql/data/log/postgresql-*.log   # today's log
sudo journalctl -u postgresql -e                          # if logging to journald
```

**Rotation — PostgreSQL does it itself.** There is **no
`/etc/logrotate.d/postgresql`** because the logging collector rotates its own
files. You configure it in `postgresql.conf` (inside the data dir — which your
profile already grants), not with logrotate:
```conf
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%a.log'   # %a = weekday; files recycle weekly
log_rotation_age = 1d                # rotate daily...
log_rotation_size = 100MB            # ...or at 100 MB, whichever first
log_truncate_on_rotation = on        # overwrite last week's file, don't append
```
`sudo systemctl reload postgresql` to apply. This keeps roughly a week of logs
in a fixed set of files with no external tooling.

## Cheat sheet

```bash
sudo postgresql-setup --initdb                   # ONE-TIME: create the cluster
sudo systemctl enable --now postgresql           # then start
systemctl status postgresql                      # health
sudo -u postgres vi /var/lib/pgsql/data/pg_hba.conf   # client auth
sudo systemctl reload postgresql                 # apply pg_hba/config changes
sudo -u postgres psql                            # SQL shell
sudo -u postgres pg_dump appdb > appdb.sql       # backup
sudo -l                                          # what am I allowed to do?
```
