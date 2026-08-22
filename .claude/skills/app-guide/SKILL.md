---
name: app-guide
description: Generate an evidence-based application deployment guide (docs/applications/<app>.md) plus a reviewed access profile (examples/<app>-access.yml) for a dnf-installable EL app. Use when asked to document how a web server, database, or other package is installed, set up, administered, and locked down under the declarative_access lifecycle. Grounds every "what the install creates" claim in a real treadmark footprint captured in a container — never write these from memory.
---

# Writing an application deployment guide

Produce, for one dnf-installable application, a guide aimed at a
**college-freshman-or-older** reader that covers: what it does, how to install
and **set it up properly** (trackable drop-in configs), what the install
actually creates (accounts, units, dirs, configured access), how to administer
its systemd service, and the **before/after** of restricting access to the
`app-restricted` group. Model everything on the existing
`docs/applications/httpd.md` — it is the reference implementation.

## Non-negotiable: capture real evidence first

Never describe "what the install creates" from memory. Install the app in a
clean systemd container, capture a treadmark footprint, and write from the JSON.
The helper script does the whole dance:

```bash
scripts/capture-app-footprint.sh <package> [el9|el10] [extra dnf pkgs...]
# e.g.
scripts/capture-app-footprint.sh nginx el9
scripts/capture-app-footprint.sh mariadb-server el9
```

It prints, and leaves in `/tmp/app-guide-<package>/`:

- `footprint-<app>.json` — the full model,
- `<app>-access.yml` — the RAW generated profile,
- an **EVIDENCE** block: summary counts, users/groups created, systemd units
  (with `unit_type`, `User=`, `activates` for timers), risk kinds + high/critical
  details, and config/state/log directories.

Read the EVIDENCE block and the raw profile. Those are your facts.

Requires Docker (on macOS: `export DOCKER_HOST=unix://$HOME/.docker/run/docker.sock`)
and the treadmark source tree (`export TREADMARK_SRC=/path/to/treadmark`).

## Guide structure (match httpd.md)

1. **What is it?** — one paragraph, plain language, plus what port(s) it opens.
2. **Quick facts table** — package (+EL9/EL10 versions from
   `docs/applications/README.md`), unit name, service account, main config,
   *where your config goes* (the drop-in dir), data/log dirs, config-test
   command, ports.
3. **Installing** — the `dnf install` + `systemctl enable --now` during the
   app-full setup window.
4. **What the install sets up** — straight from the footprint: the service
   account (uid/shell), a units table, a directories table with captured
   ownership, and an **access-configured** subsection explaining every entry in
   `risks[]` in plain terms (e.g. "runs as root because only root binds port
   80, then drops to the service user" — don't just list it, explain whether it
   is normal).
5. **Setting it up properly: drop-in configs** — the golden rule (never edit
   the vendor main config), a concrete drop-in example, config-test-then-reload,
   and an SELinux note if the app serves/binds outside defaults.
6. **Administering the service** — a task→command table; explain reload vs
   restart. **Use the EXACT granted command forms** (see gotcha below).
7. **Before/after access** — setup window (app-full = wheel), the
   capture+review (show raw-vs-reviewed reasoning), then the restricted world:
   a "still yours" block and a "gone" block of real allowed/denied commands.
8. **Cheat sheet** — the 6–8 commands they'll actually use.

## The sudoers exact-command gotcha (put this in every guide)

`sudo` matches the whole command line, **argument order included**. The role
grants specific journalctl forms: `journalctl -u <svc>`, `journalctl -e -u
<svc>`, `journalctl -ef -u <svc>`, `journalctl --since -5m|-10m|-15m -u <svc>`
(each also with the `.service` suffix). `journalctl -u <svc> -e` (options after
the unit) is a *different string* and prompts for a password. Always write the
granted spelling, and tell the reader `sudo -l` shows the exact list.

## Writing the reviewed access profile (examples/<app>-access.yml)

Start from the raw profile, then tighten — and **explain each edit in comments**:

- **Drop vendor unit-file write ACLs.** Files under `/usr/lib/systemd/system`
  or `/lib/systemd/system` are RPM-owned; write ACLs trip `rpm -V` and aren't
  needed. Most base-repo services are this case → a *read-only-units* profile.
  (Keep `files_modify` only for units the team authored under
  `/etc/systemd/system` or `/etc/containers/systemd`.)
- **Drop bundled-but-unused units** (e.g. httpd's `htcacheclean`) unless the
  setup uses them.
- **Add content/log dirs the footprint missed** — app data outside the config
  tree (`/var/www`, a DB data dir) and `/var/log/<app>` (`/var/log` is excluded
  from footprints by default). Note these as reviewer additions.
- **Keep ownership entries** treadmark captured for install-created accounts.
- **Never** set `declarative_access_user`/`_group` — the operator passes the
  team at apply time.

## Verify the profile before finalizing (strongly recommended)

The capture container is still running with the app installed. Apply the
reviewed profile to a simulated local group and prove the before/after, exactly
as the httpd guide claims were proven:

```bash
scripts/verify-app-profile.sh <package>   # applies examples/<app>-access.yml,
                                           # runs allow/deny/revoke checks
```

If a "still yours" command is denied or a "gone" command is allowed, fix the
profile (or the guide's command spelling) and re-run. Only claim
"verified end to end" in the guide if this passed.

## Finish

- Flip the row in `docs/applications/README.md` from `—` to
  `✅ [<app>.md](<app>.md)`.
- `ansible-lint -c .github/workflows/etc/.ansible-lint` stays 0/0 (docs +
  example vars are lint-visible).
- `docker rm -f app-guide-<package>` to clean up.
- Commit (from the real checkout) as `docs: add <app> application guide` — the
  example profile makes it user-facing, but semantic-release ignores `docs`
  scopes without a release-worthy type, which is correct for a guide.
