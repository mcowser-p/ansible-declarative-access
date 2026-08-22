# Apache Tomcat — a Java web-application server

*Audience: college-freshman level and up. Every "what the install creates"
fact comes from a real treadmark footprint of `dnf install tomcat` on AlmaLinux 9
(Tomcat 9.0) — not from memory.*

## What is it?

Most web servers (httpd, nginx) serve files and forward requests. **Tomcat**
is different: it *runs Java web applications*. A Java app is packaged as a
`.war` file (a "Web ARchive"); you drop that file into Tomcat's `webapps/`
directory and Tomcat unpacks and runs it. It is the standard open-source way
to run Java web apps on Linux.

Because it serves its own traffic on a **high port (8080)**, Tomcat does *not*
need to run as root — a meaningful security difference from httpd/nginx (see
below). In production it's common to put nginx or httpd in front of Tomcat to
handle HTTPS and static files, with Tomcat doing just the Java.

## Quick facts

| Thing | Value |
|---|---|
| Package | `tomcat` (EL9: 9.0, EL10: 10.1) |
| Service unit | `tomcat.service` |
| Service account | `tomcat` (uid 53, `nologin`) — **runs as this user, not root** |
| Config | `/etc/tomcat/` (`server.xml`, `tomcat.conf`, `context.xml`) |
| Deploy apps to | `/var/lib/tomcat/webapps/` (drop `.war` files here) |
| Logs | `/var/log/tomcat/` (`catalina.out` is the main one) |
| Ports | 8080 (http), 8443 (https), 8005 (shutdown) |
| Needs | a JDK (pulled in automatically — ~1,300 files) |

## 1. Installing (during your setup window)

```bash
sudo dnf install tomcat
sudo systemctl enable --now tomcat
systemctl status tomcat            # "active (running)"
# Tomcat is now listening on http://localhost:8080
```

## 2. What the install actually sets up

Tomcat is a big install — **1,329 files added** — because it drags in a whole
Java runtime (the JDK). The parts that matter:

**A service account, used properly.** The `tomcat` user and group (uid/gid
53, `nologin`). Unlike httpd/nginx, `tomcat.service` sets **`User=tomcat`** —
the footprint confirms it — so Tomcat never runs as root. The footprint
reports **zero risks**, which is exactly what you want from a service that
binds only unprivileged ports.

**Systemd units** (vendor-owned): `tomcat.service` and `tomcat@.service` (a
template for running multiple named instances).

**Directories:**

| Path | Purpose | Ownership |
|---|---|---|
| `/etc/tomcat/` | `server.xml`, `tomcat.conf`, contexts | `root:tomcat 0755` |
| `/var/lib/tomcat/webapps/` | **Deploy `.war` files here** | `root:tomcat 0755` |
| `/var/lib/tomcat/` | `work/`, `temp/` (runtime) | `root:tomcat 0755` |
| `/var/log/tomcat/` | `catalina.out` + app logs | tomcat |

The footprint *also* recorded a pile of JDK directories (`/etc/java`,
`/etc/jvm`, `/etc/.java`, `/etc/pki/nssdb`). Those belong to the **shared Java
runtime**, not to your Tomcat — the review drops them (see §6).

## 3. Setting it up properly

Tomcat's configuration model is different from the drop-in `conf.d/` style of
httpd/nginx — its central config is one XML file, `/etc/tomcat/server.xml`,
and applications are deployed as files. Two clean, trackable habits:

**Deploy apps by dropping a WAR** (don't hand-edit unpacked apps):

```bash
# Your build produces hello.war — deploy it:
sudo cp hello.war /var/lib/tomcat/webapps/
sudo chown root:tomcat /var/lib/tomcat/webapps/hello.war
# Tomcat auto-detects and unpacks it to webapps/hello/ within seconds.
# It's now at http://localhost:8080/hello
```

**Change JVM settings in a drop-in, not the main script.** Memory and Java
options go in `/etc/tomcat/conf.d/*.conf` (loaded by `tomcat.conf`), e.g.:

```bash
echo 'JAVA_OPTS="-Xms512m -Xmx1024m"' | sudo tee /etc/tomcat/conf.d/memory.conf
sudo systemctl restart tomcat     # JVM options need a full restart
```

Editing `server.xml` (ports, connectors, TLS) is expected — just keep changes
minimal and reviewed; it is one file, so a diff tells the whole story.

**SELinux:** Tomcat runs confined. If an app needs to open network
connections (to a database, say), you may need
`sudo setsebool -P tomcat_can_network_connect_db on` or the general
`tomcat_can_network_connect on`.

## 4. Administering the service

| Task | Command |
|---|---|
| Start / stop | `sudo systemctl start tomcat` / `stop tomcat` |
| Apply config or app changes | `sudo systemctl restart tomcat` |
| Start at boot / not | `sudo systemctl enable tomcat` / `disable tomcat` |
| Is it running? | `systemctl status tomcat` |
| Service logs | `sudo journalctl -u tomcat` |
| Application logs | `/var/log/tomcat/catalina.out` |

**Note there is no graceful `reload` for Tomcat** — unlike httpd/nginx, config
and JVM changes need a full `restart`. (Deploying a new WAR is the exception:
Tomcat hot-deploys it without a restart.) Watch `catalina.out` after a restart
— Java stack traces there are how you diagnose an app that won't start.

> **Exact-command gotcha (once restricted):** granted journalctl forms are
> `journalctl -u tomcat`, `-e -u tomcat`, `-ef -u tomcat`, `--since -5m -u
> tomcat` (+`-10m`/`-15m`). Match them exactly, or run `sudo -l`.

## 5. HTTPS / TLS — the keystore difference

Java does **not** read PEM certificate files the way nginx and httpd do. It
uses a **keystore** — a single binary file (PKCS12 format) holding the
certificate and private key together. You convert your PEM cert+key into a
keystore, then point a TLS connector in `server.xml` at it. The full
procedure (and the common alternative of terminating TLS at an nginx/httpd
front end instead) is in **[TLS/SSL administration](tls-ssl.md#tomcat-uses-a-java-keystore)**.

## 6. The access lifecycle: before & after

Standard [application deployment lifecycle](../application-deployment-lifecycle.md).

**Before — setup window (app admin):** full admin. Install, deploy your WAR,
tune `server.xml`, confirm it serves on 8080.

**Capture & review:** the reviewer tightens the generated profile
([examples/tomcat-access.yml](../../examples/tomcat-access.yml)) — this is the
clearest example of why review matters. The raw profile grabbed **every JDK
and JVM directory on the system** (`/etc/java`, `/etc/jvm`, `/etc/.java`,
`/etc/pki/nssdb`) plus the multi-instance `/var/lib/tomcats`. None of those are
your app's config; they're shared system runtime, so the reviewer drops them
(and the vendor unit ACLs). For access, Tomcat is the **easiest** case:
**pam_group into the `tomcat` group** is all that's needed to deploy WARs,
because the package already ships `/var/lib/tomcat/webapps` as `0775
root:tomcat` — no setgid or ACL required there. treadmark's footprint confirms this
in its `group_access` section, which shows the `tomcat` group already has write
on `webapps` **and** on `/etc/tomcat/Catalina` (per-app context configs) — so
pam_group covers those with zero drift. Only editing the top-level config files
(`server.xml`, `tomcat.conf`) needs an ACL on `/etc/tomcat`, and log read
(`/var/log/tomcat`, `tomcat:root 0770`) is an ACL. See
[File access: pam_group and ACLs](../declarative-systemd-access.md#file-access-pam_group-and-acls).

**After — restricted admin.** Verified end to end against a real running
Tomcat:

| ✓ Still yours | ✕ Gone |
|---|---|
| `sudo systemctl start/stop/restart/status tomcat` | `sudo systemctl restart sshd` |
| `sudo journalctl -u tomcat` (+ variants) | `sudo dnf install …` |
| deploy WARs to `/var/lib/tomcat/webapps` (ACL) | edit `/etc/java`, `/etc/jvm` (shared JDK) |
| edit `/etc/tomcat/server.xml` (ACL) | edit `/usr/lib/systemd/system/tomcat.service` |
| read `/var/log/tomcat/*` (ACL) | anything not Tomcat |

## Logs & log rotation

See [logging.md](logging.md) for the shared concepts. Tomcat's logging has a
real trap, so read this one.

**What gets created**, all in **`/var/log/tomcat/`**:
- **`catalina.out`** — the main log; everything the JVM and your app print.
- **`catalina.YYYY-MM-DD.log`**, **`localhost.<date>.log`**,
  **`localhost_access_log.<date>.txt`** — Tomcat's internal logging (JULI) writes
  these, **date-stamped, one per day**.

**How to view:**
```bash
sudo tail -f /var/log/tomcat/catalina.out            # app output + stack traces
sudo less /var/log/tomcat/localhost_access_log.$(date +%F).txt   # today's requests
sudo journalctl -u tomcat -e                          # service lifecycle
```

**Rotation — the trap.** Tomcat's JULI already rotates the *date-stamped* files
daily. But **`catalina.out` is NOT rotated by anything and grows forever** — on
a busy server it will eventually fill the disk. The package ships a logrotate
fragment for it, but **disabled**: `/etc/logrotate.d/tomcat.disabled`. To turn
it on:
```bash
sudo cp /etc/logrotate.d/tomcat.disabled /etc/logrotate.d/tomcat
# then edit /etc/tomcat/logging.properties so JULI does NOT also rotate it
```
It uses **`copytruncate`** (copy `catalina.out` aside, then truncate it in
place) because Tomcat can't be signalled to reopen that file. Set a sensible
`rotate` count and `compress`. This is the single most common Tomcat disk
surprise — enable it during setup.

## Cheat sheet

```bash
systemctl status tomcat                          # health
sudo cp myapp.war /var/lib/tomcat/webapps/       # deploy an app
sudo vi /etc/tomcat/conf.d/memory.conf           # JVM tuning (drop-in)
sudo systemctl restart tomcat                    # apply config/JVM changes
sudo journalctl -u tomcat                        # service logs
tail -f /var/log/tomcat/catalina.out             # app logs / stack traces
sudo -l                                          # what am I allowed to do?
```
