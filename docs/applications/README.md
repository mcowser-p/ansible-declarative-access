# Application guides

Per-application guides for software teams deploy on our EL servers with
`dnf`. Each guide covers, for a reader at the college-freshman level or up:

- what the application does,
- how it is installed and how to **set it up properly** (drop-in config
  files, so changes are trackable),
- what the install actually creates on the system — service accounts,
  systemd units, directories, and any access it configures — **grounded in
  a real cairn footprint**, not folklore,
- how to administer its systemd service, and
- what changes **before vs. after** access is limited to the restricted
  admin group (the [application deployment lifecycle](../application-deployment-lifecycle.md)).

Guides are generated with the `app-guide` skill (`.claude/skills/app-guide/`):
the application is installed in a clean systemd container, cairn captures the
footprint, and the guide + example access profile are written from that
evidence.

## The menu — verified against AlmaLinux base repos (2026-07)

Pick any application below to have its guide generated.

### Web servers & proxies

| Application | Package | EL9 | EL10 | Guide |
|---|---|---|---|---|
| Apache httpd | `httpd` | 2.4.62 | 2.4.63 | ✅ [httpd.md](httpd.md) |
| nginx | `nginx` | 1.20 | 1.26 | ✅ [nginx.md](nginx.md) |
| Apache Tomcat (Java) | `tomcat` | 9.0 | 10.1 | ✅ [tomcat.md](tomcat.md) |
| HAProxy (load balancer) | `haproxy` | 2.8 | 3.0 | — |
| Squid (caching proxy) | `squid` | 5.5 | 6.10 | — |
| Varnish (HTTP cache) | `varnish` | 6.6 | 7.6 | — |
| PHP-FPM (PHP runtime) | `php-fpm` | 8.0 | 8.3 | — |

### Databases & caches

| Application | Package | EL9 | EL10 | Guide |
|---|---|---|---|---|
| PostgreSQL | `postgresql-server` | 13 (streams to 15/16) | 16 | ✅ [postgresql.md](postgresql.md) |
| MySQL | `mysql-server` | 8.0 | *(not in EL10 — use MariaDB)* | ✅ [mysql.md](mysql.md) |
| MariaDB | `mariadb-server` | 10.5 | 10.11 | — (see [mysql.md](mysql.md)) |
| Redis | `redis` | 6.2 | *(replaced by Valkey)* | — |
| Valkey (Redis fork) | `valkey` | 8.0 | 8.0 | — |
| Memcached | `memcached` | 1.6 | 1.6 | — |

### Cross-cutting

| Topic | Guide |
|---|---|
| TLS / SSL administration (certs, keys, per-service HTTPS, renewal) | ✅ [tls-ssl.md](tls-ssl.md) |
| Logs, viewing them (`journalctl` + files), and log rotation | ✅ [logging.md](logging.md) |

Notes:

- Versions are the default appstream package in the AlmaLinux 9/10 base
  repos; PostgreSQL and others offer newer module streams
  (`dnf module list postgresql`).
- EL10 dropped `redis` (license change) in favor of `valkey`, and ships no
  `mysql-server` — MariaDB is the EL10 MySQL-compatible option.
- lighttpd and Caddy are **not** in the base repos (EPEL only) and are out
  of scope for the standard menu.
