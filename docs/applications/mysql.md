# MySQL — a relational database server

*Audience: college-freshman level and up. Every "what the install creates"
fact comes from a real treadmark footprint of `dnf install mysql-server` on
AlmaLinux 9 (MySQL 8.0) — not from memory.*

> **EL10 note:** AlmaLinux 10 does **not** ship `mysql-server`. On EL10 use
> **MariaDB** (`dnf install mariadb-server`) — a drop-in-compatible fork with
> the same tables, SQL, and client tools. Its service is `mariadb.service`
> and its config lives in the same `/etc/my.cnf.d/`; everything below applies
> with those two names swapped.

## What is it?

A **relational database** stores data in tables (rows and columns) and lets
applications query it with SQL. **MySQL** is one of the most widely used
open-source databases — the "M" in the classic "LAMP" stack (Linux, Apache,
MySQL, PHP). An application connects to it over the network (default port
**3306**) or a local socket, and reads/writes its data there.

Unlike a web server, a database is **not** meant to be exposed to the public
internet — it listens for your *application* to connect, usually from the same
host or a private network.

## Quick facts

| Thing | Value |
|---|---|
| Package | `mysql-server` (EL9: 8.0) · EL10: use `mariadb-server` |
| Service unit | `mysqld.service` (note the **d**) |
| Service account | `mysql` (uid 27, `nologin`) — runs as this user |
| Main config | `/etc/my.cnf` |
| Your config goes in | `/etc/my.cnf.d/*.cnf` (drop-ins) |
| Data directory | `/var/lib/mysql/` (**the databases themselves**) |
| Logs | journald — `sudo journalctl -u mysqld` |
| Port | 3306 |

## 1. Installing (during your setup window)

```bash
sudo dnf install mysql-server
sudo systemctl enable --now mysqld   # first start initializes the data dir
systemctl status mysqld
```

## 2. What the install actually sets up

A large install — **2,821 files added** — the relevant parts:

**A service account.** The `mysql` user and group (uid/gid 27, `nologin`);
`mysqld.service` runs as `User=mysql`.

**Directories:**

| Path | Purpose | Ownership |
|---|---|---|
| `/etc/my.cnf.d/` | **Your** config drop-ins | root |
| `/var/lib/mysql/` | The databases (data files) | `mysql:mysql 0755` |
| `/var/lib/mysql-files/` | Import/export staging area | `mysql:mysql 0750` |
| `/var/lib/mysql-keyring/` | Keys for at-rest encryption | `mysql:mysql 0700` |

**Two findings worth knowing** (from `risks[]`):

> **`/usr/libexec/mysqld` carries file capabilities.** The server binary is
> granted a Linux capability (for locking memory / real-time scheduling) so it
> can perform better without running as full root. Expected for a database —
> noted, not a problem.

> **The raw footprint also captured SELinux and man-page bits that are NOT
> MySQL's.** Installing the package scheduled a one-time SELinux relabel and
> pulled in `groff` (man-page formatting). Those show up in the raw profile as
> `selinux-autorelabel` services and `/etc/groff` — and the review removes
> them (see §5). This is the sharpest example of why a human reads the profile
> before it's applied: you do **not** want to hand an app team the ability to
> trigger a full-system SELinux relabel.

## 3. Setting it up properly

**First start initializes everything.** The very first `systemctl start
mysqld` creates the system tables in `/var/lib/mysql` and generates a
**temporary root password**. Find it, then secure the install:

```bash
sudo grep 'temporary password' /var/log/mysql/mysqld.log
# ...or, if logging to journald:
sudo journalctl -u mysqld | grep 'temporary password'

sudo mysql_secure_installation      # set a real root password, remove test
                                     # DB + anonymous users — answer "yes" to
                                     # the hardening prompts
```

**Configure with drop-ins**, never by editing `/etc/my.cnf` (which just says
"include `my.cnf.d/`"):

```bash
sudo tee /etc/my.cnf.d/app.cnf > /dev/null <<'EOF'
[mysqld]
# bind to localhost only unless a remote app truly needs 3306
bind-address = 127.0.0.1
max_connections = 200
EOF
sudo systemctl restart mysqld       # config changes need a restart
```

**Create the app's database and user** (never let the app use root):

```bash
mysql -u root -p <<'SQL'
CREATE DATABASE appdb;
CREATE USER 'appuser'@'localhost' IDENTIFIED BY 'a-strong-password';
GRANT ALL PRIVILEGES ON appdb.* TO 'appuser'@'localhost';
FLUSH PRIVILEGES;
SQL
```

## 4. Administering the service

| Task | Command |
|---|---|
| Start / stop | `sudo systemctl start mysqld` / `stop mysqld` |
| Apply config changes | `sudo systemctl restart mysqld` |
| Start at boot / not | `sudo systemctl enable mysqld` / `disable mysqld` |
| Is it running? | `systemctl status mysqld` |
| Service logs | `sudo journalctl -u mysqld` |
| Open a SQL shell | `mysql -u root -p` |
| Back up a database | `mysqldump appdb > appdb.sql` |

> **Restart, don't just reload:** MySQL config changes require a full
> `restart`. Plan for a brief interruption — applications will drop their
> connections and reconnect.

> **Exact-command gotcha (once restricted):** granted journalctl forms are
> `journalctl -u mysqld`, `-e -u mysqld`, `-ef -u mysqld`, `--since -5m -u
> mysqld` (+`-10m`/`-15m`). Note the **`d`** in `mysqld`. `sudo -l` shows the
> exact list.

## 5. Encrypting connections (TLS)

MySQL 8 **auto-generates self-signed certificates** in `/var/lib/mysql` on
first start, so connections can already be encrypted. To use real CA-signed
certificates, or to *require* TLS for every connection, set `ssl-ca` /
`ssl-cert` / `ssl-key` and `require_secure_transport=ON` in a `my.cnf.d`
drop-in. The details are in
**[TLS/SSL administration](tls-ssl.md#databases-encrypt-the-connection)**.

## 6. The access lifecycle: before & after

Standard [application deployment lifecycle](../application-deployment-lifecycle.md).

**Before — setup window (app admin):** full admin. Install, run
`mysql_secure_installation`, create the app's database and user, tune with a
drop-in.

**Capture & review:** the reviewer tightens the profile
([examples/mysql-access.yml](../../examples/mysql-access.yml)) —
services becomes **`[mysqld]` only** (the `selinux-autorelabel` units are
dropped), `/etc/groff` is dropped, vendor + SELinux unit ACLs are dropped, and
the `mysql` data/keyring ownership entries are kept.

Unlike the web servers, the DB profile is **config-scoped and does NOT add the
team to the `mysql` group**: that group owns the raw data files, and you
administer MySQL through the SQL client, not the filesystem. So it grants only
`/etc/my.cnf.d` (write) and `/var/log/mysql` (read) via ACL. If you *do* want
the team in the `mysql` group (it already grants log read, and file-level ops),
that's the documented group option —
`-e enable_pam_group=true -e '{"declarative_access_local_groups":["mysql"]}'`
(see [File access: pam_group and ACLs](../declarative-systemd-access.md#file-access-pam_group-and-acls)).
Applied to `<hostname>-app_restricted`.

**After — restricted admin.** Verified end to end against a real MySQL:

| ✓ Still yours | ✕ Gone |
|---|---|
| `sudo systemctl start/stop/restart/status mysqld` | `sudo systemctl restart sshd` |
| `sudo journalctl -u mysqld` (+ variants) | **`sudo systemctl … selinux-autorelabel`** |
| edit `/etc/my.cnf.d/*.cnf` (ACL) | `sudo dnf install …` |
| read/manage `/var/lib/mysql*` (ACL) | edit vendor unit files |
| `mysql -u root -p` (DB-level admin) | anything not MySQL |

Note the distinction: your restricted access lets you *operate the MySQL
service* and, with the DB root password, administer *inside* the database —
but it cannot touch the rest of the host.

## Logs & log rotation

See [logging.md](logging.md) for the shared concepts. MySQL specifics:

**What gets created.** By default MySQL writes its **error log** to
**`/var/log/mysql/mysqld.log`** (set by `log-error` in
`/etc/my.cnf.d/mysql-server.cnf`). This is where startup problems, crashes, and
the first-run temporary password appear. The slow-query log and general log are
off by default; enable them in a `my.cnf.d` drop-in if needed. The journal holds
service lifecycle.

**How to view:**
```bash
sudo tail -f /var/log/mysql/mysqld.log       # follow the error log
sudo grep -i error /var/log/mysql/mysqld.log
sudo journalctl -u mysqld -e                  # service start/stop/crash
```

**Rotation — off by default.** MySQL ships `/etc/logrotate.d/mysqld`, but its
contents are **entirely commented out** — the package leaves rotation as an
opt-in decision. To enable it, uncomment the block:
```bash
sudo vi /etc/logrotate.d/mysqld              # uncomment the /var/log/mysql/... block
sudo logrotate -d /etc/logrotate.d/mysqld    # dry-run to confirm
```
The shipped example flushes the log with `kill -USR1 $(systemctl show --property
MainPID --value mysqld)` — note it needs **no database credentials** (older MySQL
logrotate used `mysqladmin` and a password, which was a headache; the signal
approach avoids it).

## Cheat sheet

```bash
systemctl status mysqld                          # health
sudo journalctl -u mysqld | grep 'temporary password'   # first-run password
sudo mysql_secure_installation                   # secure a fresh install
sudo vi /etc/my.cnf.d/app.cnf                     # config (drop-ins!)
sudo systemctl restart mysqld                     # apply config changes
mysql -u root -p                                  # SQL shell
mysqldump appdb > appdb.sql                       # backup
sudo -l                                           # what am I allowed to do?
```
