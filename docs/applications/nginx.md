# nginx — a fast web server and reverse proxy

*Audience: college-freshman level and up. Every "what the install creates"
fact comes from a real treadmark footprint of `dnf install nginx` on AlmaLinux 9
(nginx 1.20) — not from memory.*

## What is it?

**nginx** (say "engine-x") is a web server, like Apache httpd, but built
around a different design that makes it very fast at two jobs: serving
**static files** (images, HTML, CSS) and acting as a **reverse proxy** — sitting
in front of an application (a Python/Node/Java app) and forwarding requests to
it, often while handling HTTPS on the app's behalf. On our fleet you'll most
often see nginx as the public front door for an application that runs behind
it.

Once started, it answers on **port 80** (HTTP); with certificates it also
serves **port 443** (HTTPS — see [TLS/SSL administration](tls-ssl.md)).

## Quick facts

| Thing | Value |
|---|---|
| Package | `nginx` (EL9: 1.20, EL10: 1.26) |
| Service unit | `nginx.service` |
| Service account | `nginx` (uid 998, `nologin`) |
| Main config | `/etc/nginx/nginx.conf` — includes everything in `conf.d/` |
| Your config goes in | `/etc/nginx/conf.d/*.conf` (drop-ins) |
| Web content | `/usr/share/nginx/html` (default), or `/var/www` |
| Logs | `/var/log/nginx/` (`access.log`, `error.log`) |
| Test config | `nginx -t` |
| Ports | 80 (http), 443 (https) |

## 1. Installing (during your setup window)

While your account is in the **app admin** group (`<hostname>-app_full`):

```bash
sudo dnf install nginx
sudo systemctl enable --now nginx   # start now and on every boot
systemctl status nginx              # "active (running)"
```

## 2. What the install actually sets up

The footprint of this install is **lean — 85 files added**, 35 modified:

**A service account.** The `nginx` user and group (uid/gid 998, `nologin`).
The master process starts as root; its worker processes drop to `nginx`.

**Systemd units** (vendor-owned): `nginx.service`. Installing nginx also
pulls in the **system `logrotate`** service + timer as a dependency — that is
the OS's log rotation, *not* nginx's, and the review drops it from your
profile (more below).

**Directories:**

| Path | Purpose | Ownership |
|---|---|---|
| `/etc/nginx/` | Config — `nginx.conf` + `conf.d/` | root |
| `/etc/nginx/conf.d/` | **Your** drop-in configs | root |
| `/usr/share/nginx/html/` | Default web content | root |
| `/var/lib/nginx/` | Runtime state (cache, tmp) | `nginx:root 0770` |
| `/var/log/nginx/` | Access + error logs | root |

**One finding to understand** (from the footprint's `risks[]`):

> **`nginx.service` has no `User=` — the master runs as root.** Normal and
> deliberate, exactly as with httpd: only root can bind port 80, so the root
> master binds the port and spawns unprivileged `nginx` workers that handle
> every request. Not a problem to fix — a fact to know.

## 3. Setting it up properly: drop-in config files

nginx's main file `/etc/nginx/nginx.conf` ends with `include
/etc/nginx/conf.d/*.conf;`. So **you never edit the main file** — you drop one
file per site into `conf.d/`. One file, one intention, easy to track and
review.

```bash
sudo mkdir -p /var/www/hello
echo '<h1>hello</h1>' | sudo tee /var/www/hello/index.html

sudo tee /etc/nginx/conf.d/hello.conf > /dev/null <<'EOF'
# One site, one file.
server {
    listen 80;
    server_name hello.example.edu;
    root /var/www/hello;

    access_log /var/log/nginx/hello_access.log;
    error_log  /var/log/nginx/hello_error.log;
}
EOF

sudo nginx -t                     # ALWAYS test first: "syntax is ok"
sudo systemctl reload nginx       # graceful reload, no dropped connections
```

**SELinux (EL is enforcing):** content under `/usr/share/nginx/html` and
`/var/www` is labeled correctly. Serving elsewhere, or **reverse-proxying to
a backend**, needs a boolean or label — the classic one is
`sudo setsebool -P httpd_can_network_connect on` so nginx may open
connections to your app. A proxy that returns `502` with "Permission denied"
in `error.log` is usually this.

## 4. Administering the service

| Task | Command |
|---|---|
| Start / stop | `sudo systemctl start nginx` / `stop nginx` |
| Apply config changes | `sudo nginx -t && sudo systemctl reload nginx` |
| Full restart | `sudo systemctl restart nginx` |
| Start at boot / not | `sudo systemctl enable nginx` / `disable nginx` |
| Is it running? | `systemctl status nginx` |
| Service logs | `sudo journalctl -u nginx` |
| Web traffic logs | `/var/log/nginx/access.log`, `error.log` |

**reload** sends nginx a signal to re-read config gracefully (existing
connections finish on the old config); **restart** stops and restarts the
processes. Prefer `reload` for config changes — and always `nginx -t` first.

> **Exact-command gotcha (once restricted):** `sudo` matches the whole
> command line including argument order. The granted journalctl forms are
> `journalctl -u nginx`, `-e -u nginx`, `-ef -u nginx`, and `--since -5m -u
> nginx` (also `-10m`/`-15m`). `journalctl -u nginx -e` is a different string
> and prompts for a password. `sudo -l` shows the exact allowed lines.

## 5. HTTPS / TLS

nginx reads its certificate and key as plain PEM files and adds an
`ssl`-enabled `listen 443`:

```nginx
server {
    listen 443 ssl;
    server_name hello.example.edu;
    root /var/www/hello;

    ssl_certificate     /etc/pki/tls/certs/hello.example.edu.crt;
    ssl_certificate_key /etc/pki/tls/private/hello.example.edu.key;
}
```

Getting the certificate, where the files live, protecting the private key,
and reloading after renewal are all in **[TLS/SSL administration](tls-ssl.md)** —
read it before you enable HTTPS.

## 6. The access lifecycle: before & after

Standard [application deployment lifecycle](../application-deployment-lifecycle.md).

**Before — setup window (app admin):** full admin via `wheel`. Install,
configure with drop-ins, get it serving. Keep it short.

**Capture & review:** treadmark generates the profile; the reviewer shapes it
(reasoning in [examples/nginx-access.yml](../../examples/nginx-access.yml);
mechanism in [File access: pam_group and ACLs](../declarative-systemd-access.md#file-access-pam_group-and-acls))
exactly like httpd — **pam_group into the `nginx` group** for the baseline,
**web content (`/usr/share/nginx/html`) group-owned + setgid** so the team
writes it through the group, and **ACLs for config (`/etc/nginx`) write and
log (`/var/log/nginx`) read**. It also **drops the system `logrotate`
service+timer** (not nginx's to run) and the vendor unit-file ACLs. Then it's
applied to `<hostname>-app_restricted`.

> **Note — the setgid on `/usr/share/nginx/html` is intentional drift.** Like
> httpd, nginx ships no group-writable content dir, so the profile makes the
> web root group-owned + setgid to grant content writes through the group.
> That deviates from vendor ownership, so `rpm -V` / treadmark drift checks flag it
> — record it in the golden-baseline accept-list as reviewed drift.

**After — restricted admin.** Verified end to end against a real running
nginx:

| ✓ Still yours | ✕ Gone |
|---|---|
| `sudo systemctl start/stop/restart/reload/status nginx` | `sudo systemctl restart sshd` |
| `sudo journalctl -u nginx` (+ variants) | `sudo dnf install …` |
| edit `/etc/nginx/conf.d/*.conf` (ACL) | edit `/usr/lib/systemd/system/nginx.service` |
| edit web content in `/usr/share/nginx/html` (ACL) | `sudo systemctl … logrotate` |
| read `/var/log/nginx/*` (ACL) | anything not nginx |

Need TLS added later, or a proxy to a new backend? That's a **change
window**: back to app-full, configure, re-capture, re-review, re-apply, flip
back.

## Logs & log rotation

See [logging.md](logging.md) for the shared concepts. nginx specifics:

**What gets created.** nginx writes **`/var/log/nginx/access.log`** and
**`error.log`** (plus any per-site logs you set with `access_log`/`error_log` in
a `conf.d` server block). The journal holds only lifecycle events.

**How to view:**
```bash
sudo tail -f /var/log/nginx/error.log        # follow errors live
sudo less /var/log/nginx/access.log          # page through requests
sudo journalctl -u nginx -e                   # service start/stop/crash
```

**Rotation.** nginx ships an **active** `/etc/logrotate.d/nginx`, already tuned:
**daily**, **keep 10**, **compress**. After rotating it sends nginx `USR1`,
which makes it reopen its log files instantly (no reload of the config). Nothing
to do — but you can tighten or loosen it by editing that one fragment. Verify
any change safely with a dry run:
```bash
sudo logrotate -d /etc/logrotate.d/nginx
```

## Cheat sheet

```bash
systemctl status nginx && sudo nginx -t         # health
sudo vi /etc/nginx/conf.d/mysite.conf           # change config (drop-ins!)
sudo nginx -t && sudo systemctl reload nginx     # test + apply
sudo journalctl -u nginx                         # service logs
tail -f /var/log/nginx/error.log                 # traffic errors
sudo -l                                          # what am I allowed to do?
```
