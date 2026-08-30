# Apache httpd — the Apache web server

*Audience: anyone from a college freshman up. Every fact about "what the
install creates" below comes from a real treadmark footprint captured on a clean
AlmaLinux 9 host (httpd 2.4.62, 2026-07) — not from memory.*

## What is it?

A **web server** is a program that listens on the network and answers HTTP
requests: a browser asks for a page, the server sends back the file (or the
output of an application). **Apache httpd** is the classic web server —
around since 1995, extremely configurable, and what EL distributions ship as
the default choice for hosting websites, reverse-proxying applications, and
serving PHP.

When you install and start it, your server begins answering on **port 80**
(HTTP) — add `mod_ssl` and certificates for **port 443** (HTTPS).

## Quick facts

| Thing | Value |
|---|---|
| Package | `httpd` (EL9: 2.4.62, EL10: 2.4.63) |
| Service unit | `httpd.service` |
| Service account | `apache` (uid 48, `nologin` — it cannot log in) |
| Main config | `/etc/httpd/conf/httpd.conf` — **do not edit** |
| Your config goes in | `/etc/httpd/conf.d/*.conf` (drop-ins) |
| Web content | `/var/www/` (default docroot `/var/www/html`) |
| Logs | `/var/log/httpd/` |
| Test config | `apachectl configtest` (or `httpd -t`) |
| Ports | 80 (http), 443 (https with `mod_ssl`) |

## 1. Installing (during your setup window)

You do this while your account is in the **app admin** group
(`<hostname>-app_full`) — full admin for the setup window:

```bash
sudo dnf install httpd            # add mod_ssl for HTTPS
sudo systemctl enable --now httpd # start now and on every boot
systemctl status httpd            # "active (running)"
```

## 2. What the install actually sets up

From the treadmark footprint of this exact install — **880 files added, 235
modified** — the parts that matter:

**A service account.** The RPM creates the `apache` user and group
(uid/gid 48, shell `/sbin/nologin`). This is the identity the worker
processes run as. It cannot log in — service accounts never should.

**Systemd units** (all vendor-owned, under `/usr/lib/systemd/system/`):

| Unit | What it is |
|---|---|
| `httpd.service` | The web server itself |
| `httpd.socket` | Optional socket activation (start httpd on first request) |
| `httpd@.service` | Template for running extra named instances |
| `htcacheclean.service` | Disk-cache janitor — only relevant with `mod_cache_disk` |

**Directories:**

| Path | Purpose | Owner:group mode (captured) |
|---|---|---|
| `/etc/httpd/conf/` | Main config — leave alone | `root:root 0755` |
| `/etc/httpd/conf.d/` | **Your** drop-in configs | `root:root 0755` |
| `/etc/httpd/conf.modules.d/` | Module loading | `root:root 0755` |
| `/var/www/` | Web content | `root:root 0755` |
| `/var/lib/httpd/` | Runtime state | `apache:apache 0700` |
| `/var/log/httpd/` | Access + error logs | `root:root 0700` |

**Access the install configures — two findings a reviewer should
understand, both flagged by the footprint's `risks[]`:**

1. **`httpd.service` has no `User=` — the main process runs as root.**
   This is *normal and deliberate* for httpd: only root may bind port 80.
   The root "master" process binds the port, then spawns worker processes
   that drop to the `apache` user. Requests are only ever handled by the
   unprivileged workers.
2. **`/usr/sbin/suexec` carries file capabilities** (`cap_setuid,cap_setgid`)
   — a helper that lets httpd run CGI scripts as other users. You are almost
   certainly not using it; it is safe to leave alone, but it is exactly the
   kind of thing a footprint review should notice and ask about.

## 3. Setting it up properly: drop-in config files

**Never edit `/etc/httpd/conf/httpd.conf`.** The main config belongs to the
RPM — editing it makes updates painful and hides your changes. Instead, put
each site or change in its own file under `/etc/httpd/conf.d/`; httpd loads
every `*.conf` there automatically. Drop-ins are how we track what an
application team is doing: each file is one intention, diffable, and shows
up cleanly in footprints and reviews.

```bash
sudo mkdir -p /var/www/hello
echo '<h1>hello</h1>' | sudo tee /var/www/hello/index.html

sudo tee /etc/httpd/conf.d/hello.conf > /dev/null <<'EOF'
# One site, one file. Trackable.
<VirtualHost *:80>
    ServerName hello.example.edu
    DocumentRoot /var/www/hello
    ErrorLog logs/hello_error.log
    CustomLog logs/hello_access.log combined
</VirtualHost>
EOF

sudo apachectl configtest   # ALWAYS test before reloading: "Syntax OK"
sudo systemctl reload httpd # reload = re-read config without dropping connections
```

**SELinux note (EL is enforcing by default):** content under `/var/www/` is
already labeled correctly. If you serve files from anywhere else, label
them (`semanage fcontext -a -t httpd_sys_content_t '/srv/mysite(/.*)?' &&
restorecon -Rv /srv/mysite`), and use `semanage port` if you listen on a
non-standard port. "403 Forbidden that makes no sense" is usually SELinux.

## 4. Administering the service

| Task | Command |
|---|---|
| Start / stop | `sudo systemctl start httpd` / `sudo systemctl stop httpd` |
| Apply config changes | `sudo apachectl configtest && sudo systemctl reload httpd` |
| Full restart (new modules) | `sudo systemctl restart httpd` |
| Start at boot / not | `sudo systemctl enable httpd` / `disable` |
| Is it running? | `systemctl status httpd` |
| Service logs (journald) | `sudo journalctl -u httpd` (jump to end: `-e -u httpd`; follow: `-ef -u httpd`) |
| Web traffic logs | `/var/log/httpd/access_log`, `error_log` (+ per-site logs) |

`reload` vs `restart`: **reload** re-reads config gracefully (use it for
config changes); **restart** kills and relaunches the processes (needed for
new modules; drops in-flight connections).

> **Exact-command gotcha (important once your access is restricted):** `sudo`
> matches the *exact* command line, argument order included. The journalctl
> forms your profile grants are `journalctl -u httpd`, `journalctl -e -u
> httpd`, `journalctl -ef -u httpd`, and `journalctl --since -5m -u httpd`
> (also `-10m`/`-15m`). `journalctl -u httpd -e` (options after the unit) is
> a *different* string and will ask for a password. Match the granted form,
> or just run `sudo -l` to see the exact allowed lines.

## 5. The access lifecycle: before and after

This follows the standard
[application deployment lifecycle](../application-deployment-lifecycle.md).

### Before — setup window (app admin group)

You are in `<hostname>-app_full` → mapped to `wheel` → **full admin**. All of
sections 1–4 above just work with `sudo`. This window should be short: get
httpd installed, configured with drop-ins, and serving.

### Capture and review

The platform team captures what you did and generates your access profile:

```bash
sudo treadmark footprint --config /etc/treadmark/treadmark-footprint-linux.yaml \
  --app httpd --report footprint-httpd.json --access-vars httpd-access.yml
```

The reviewer tightens the raw profile and shapes the access the way that
takes the least ongoing upkeep (full reasoning in
[examples/httpd-access.yml](../../examples/httpd-access.yml); the mechanism is
explained in
[File access: pam_group and ACLs](../declarative-systemd-access.md#file-access-pam_group-and-acls)):

- **pam_group into the `apache` group** — the team's identity for this app;
  gives the read/traverse baseline with zero per-path setup.
- **Web content (`/var/www`) group-owned + setgid `2775`** — so the team
  writes content *through group membership*, and new files inherit the group
  automatically. Verified: a team member edits content and new files land in
  the `apache` group.
- **Config (`/etc/httpd`) via an ACL** — this grants the *team* write, without
  also letting the apache service account rewrite its own config (which a
  setgid-to-`apache` would). Logs (`/var/log/httpd`, `0700` root) via a read
  ACL for the same reason.
- **Dropped the vendor unit-file ACLs** (RPM-owned; read-only units) and
  **`htcacheclean`** (unused unless you run `mod_cache_disk`).
- **Kept the ownership entry** `/var/lib/httpd → apache:apache 0700`.

> **Note — the setgid on `/var/www` is intentional drift.** httpd ships no
> group-writable content dir (unlike Tomcat's `webapps`), so the profile makes
> `/var/www` `root:apache 2775` to grant content writes through the group. That
> deviates from the vendor's `root:root 0755`, so `rpm -V` and treadmark drift
> checks will flag it — record it in the golden-baseline accept-list as
> reviewed drift.

Then it is applied to the restricted group:

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @examples/httpd-access.yml -e "group_name=<hostname>-app_restricted"
```

### What the profile creates on the target

Applying it produces exactly these artifacts — this is the complete "what are
we adding on" list to review:

| Artifact | Path / operation | What it grants |
|---|---|---|
| **sudoers file** | `/etc/sudoers.d/httpd-rg-<host>-app-restricted` | `%<hostname>-app_restricted ALL=(ALL) NOPASSWD:` the `systemctl` start/stop/restart/reload/status/enable/disable + `journalctl` + `daemon-reload` lines for `httpd` |
| **pam_group entry** | line added to `/etc/security/group.conf` | maps the AD group → local **`apache`** group at SSH login |
| **chown + setgid** | `chown -R root:apache /var/www` · `chmod 2775` | team writes web content through the `apache` group; new files inherit it |
| **ownership (enforce)** | `chown apache:apache /var/lib/httpd` · `0700` | re-asserts the captured state-dir ownership |
| **ACL (write)** | `setfacl` `rwX` for the AD group on `/etc/httpd` | edit config drop-ins |
| **ACL (read)** | `setfacl` `rX` for the AD group on `/var/log/httpd` | read logs |

The sudoers file is a real new file on the host — when you re-footprint the
finished server against the OS baseline, treadmark captures it (with its full
contents) in `privilege.sudoers_files[]`, so the exact sudo grant is part of
the record. An armed `--tags cleanup
-e declarative_access_force_cleanup=true` removes the sudoers file, the group.conf entry,
and the ACLs (the ownership/chown is state, not reverted).

### After — restricted admin group

You are moved to `<hostname>-app_restricted` (and your sessions are reset —
group changes only apply at login). Here is your world now:

**Still yours (exactly what you need to run httpd):**

```bash
sudo systemctl start|stop|restart|reload|status|enable|disable httpd
sudo journalctl -u httpd           # also: -e -u httpd, -ef -u httpd, --since -5m -u httpd
vi /var/www/hello/index.html       # your content — via apache group (setgid), no sudo
vi /etc/httpd/conf.d/hello.conf    # your config — via team ACL, no sudo
less /var/log/httpd/error_log      # read your logs — via team ACL
sudo systemctl daemon-reload       # after unit-related changes
```

All of the above was **verified end to end** against a real running httpd:
the seven `systemctl` verbs, the drop-in and content edits, and the log
reads all succeed for a restricted-group member; `sshd`, `dnf install`, and
editing the vendor unit file are all denied; and an armed `--tags cleanup` removes
every grant while httpd keeps serving.

**Gone (everything else):**

```bash
sudo systemctl restart sshd        # DENIED — not your service
sudo dnf install anything          # DENIED — installs go through change windows
vi /usr/lib/systemd/system/httpd.service   # DENIED — vendor unit, read-only
sudo -l                            # shows you the exact granted list
```

Note what "admin httpd" means here: you fully operate and configure the web
server, but you cannot escalate through it — you cannot edit its root-run
unit file, touch other services, or install software. Need something more
(say, `mod_ssl` later)? That's a **change window**: temporary move back to
app-full, install/configure, re-capture, re-review, re-apply, flip back.

## Logs & log rotation

See [logging.md](logging.md) for the shared concepts (journald vs. files,
`journalctl`, how logrotate works). httpd specifics:

**What gets created.** Apache writes its own text logs to **`/var/log/httpd/`**
— `access_log` (every request) and `error_log` (problems), plus any per-site
logs you define with `CustomLog`/`ErrorLog` in a drop-in. The systemd journal
holds only the service lifecycle (start/stop/crash).

**How to view:**
```bash
sudo tail -f /var/log/httpd/error_log        # follow errors live
sudo less /var/log/httpd/access_log          # page through requests
sudo journalctl -u httpd -e                   # did the service start? why not?
```

**Rotation.** httpd ships an **active** `/etc/logrotate.d/httpd` that rotates
`/var/log/httpd/*log` and runs `systemctl reload httpd` afterwards so Apache
reopens its files cleanly. The shipped fragment sets no frequency of its own, so
it inherits the global policy in `/etc/logrotate.conf` (typically **weekly,
keep 4**). To rotate more often or keep more history, edit that fragment — add
`daily`, `rotate 14`, and `compress`:
```bash
sudo vi /etc/logrotate.d/httpd
sudo logrotate -d /etc/logrotate.d/httpd     # dry-run: show what it would do
```

## Cheat sheet

```bash
# health
systemctl status httpd && sudo apachectl configtest

# change config (drop-ins only!)
sudo vi /etc/httpd/conf.d/mysite.conf
sudo apachectl configtest && sudo systemctl reload httpd

# logs (match the granted forms exactly)
sudo journalctl -u httpd            # or: -e -u httpd / -ef -u httpd
tail -f /var/log/httpd/error_log

# what am I allowed to do?
sudo -l
```
