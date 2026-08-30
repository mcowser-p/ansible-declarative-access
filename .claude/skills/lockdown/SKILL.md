---
name: lockdown
description: >
  Ops runbook: lock down a customer's Linux server after they finish
  deploying — capture the treadmark footprint, review it into an access
  profile, apply it with playbook 5, verify allow/deny, then flip the
  customer from <hostname>-app_full to <hostname>-app_restricted. Use when a
  customer repo's deployment manifest reads ready-for-lockdown. (app-guide
  is the maintainer skill for reference guides built in containers; this
  one operates on real AD-joined servers with real entities.)
---

# Lockdown: footprint → profile → apply → verify → flip

Canonical model: `docs/application-deployment-lifecycle.md` (phases 4–10).
This skill is the operator's command sequence for one server. Work from a
bastion or workstation that can ssh to the server and reach AD.

## Prerequisites — check every one before starting

- **This collection, from a clone root.** `ansible.cfg` resolves the role
  via `roles_path=./roles/`, so run playbook commands from the repo root.
  `ansible-galaxy collection install` is not available yet — the publish
  pipeline exists but is disabled and the GitHub repo
  (`git@github.com:mcowser-p/ansible-declarative-access.git`) has not
  received its first push; until then, use the maintainer's checkout.
- **treadmark on the server, with access-vars support.** The quadlet/timer/
  pam_group capture lives on the `claude/declarative-systemd-access-07d979`
  branch of `https://github.com/mcowser-p/treadmark.git` until it merges:
  `sudo pipx install 'git+https://github.com/mcowser-p/treadmark.git@claude/declarative-systemd-access-07d979'`.
  A main-line treadmark will silently miss quadlets. Gate:
  `treadmark footprint --help | grep -q access-vars || echo WRONG-TREADMARK`.
- **Baseline provenance.** The clean baseline must predate the setup
  window. Check the `baseline` block of a trial report, or the mtime of
  `/var/lib/treadmark/footprint-baseline.db`. A baseline created after the
  install started makes the footprint void — stop and escalate; do not
  improvise a baseline.
- **Customer inputs.** Their repo's `config/deploy/manifest.yml` with
  `status: ready-for-lockdown`, plus their `docs/applications/` and
  `docs/operations.md`.

## 1. Capture

On the server, as root:

```
sudo treadmark footprint --config /etc/treadmark/treadmark-footprint-linux.yaml \
  --app <app> --report footprint-<app>.json --access-vars <app>-access.yml
```

Exit 1 means "footprint found" — that is success. Archive both files; the
profile can be re-emitted later from the JSON with
`treadmark access-vars footprint-<app>.json -o <app>-access.yml`.

## 2. Cross-check against the manifest

The footprint is the truth; the manifest is the customer's claim. Map and
diff:

| Manifest | Profile key |
| --- | --- |
| `units` (bare `.service` names) | `declarative_access_services` (suffix stripped) |
| `units` (`*.timer`) | `declarative_access_timers` (suffix stripped) |
| `units` (quadlet-generated names) | `declarative_access_quadlets` |
| `paths.config`, `paths.data` | `declarative_access_folders_modify` |
| `paths.logs` | `declarative_access_folders_read` |
| `linger_users` | `declarative_access_linger_users` |
| `service_accounts` | `declarative_access_ownership[].owner`, `declarative_access_local_groups` candidates |

Every profile entry **not** in the manifest gets questioned before it gets
granted — ask the customer, don't guess. Every manifest entry missing from
the profile means the thing wasn't on the server at capture time: also a
conversation, before the flip, not after.

## 3. Tighten

Apply the review rules from
`docs/declarative-systemd-access.md` ("Tightening or revoking a profile" and
"File access: pam_group and ACLs") — don't restate them, follow them:

- Drop write ACLs on vendor unit files (`/usr/lib/systemd/system`,
  `/lib/systemd/system`); keep `declarative_access_files_modify` only for
  units the customer authored under `/etc/systemd/system` or
  `/etc/containers/systemd`.
- Add log/data directories the footprint missed (`/var/log` is excluded
  from capture by default) as reviewer additions.
- Keep the generated `declarative_access_ownership` entries.
- Databases are config-scoped: drop `declarative_access_pam_group` /
  `_local_groups` from DB profiles.
- The profile never contains `declarative_access_user`/`_group` — the
  entity is passed at apply time.

Commit the footprint JSON and the tightened profile to the ops record —
the PR is the approval trail.

## 4. Apply (non-breaking, while they still have full access)

From this repo's root:

```
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @<app>-access.yml -e "group_name=<hostname>-app_restricted" -l <host>
```

`app-full` is nested inside `app-restricted`, so the customer inherits the
scoped grants immediately while still holding wheel — applying can't break
their working session.

**Storage before access.** If the customer's manifest declares a `storage`
volume, or you are adding one later, **mount it before you apply** — a
filesystem mounted over an already-granted path hides the ACLs underneath
it, and the fresh mount comes up `root:root 0755` with the team locked out
and any setgid content directory reset. Any mount change after an apply
means re-running the command above (it is idempotent), then confirming with
`getfacl <path>`. On EL, also label the new mount for SELinux
(`semanage fcontext -a -e <original path> <mount>` + `restorecon -Rv`) or
the service will not start. Record mount points in the ops record so the
next reviewer knows the path is a mount.

## 5. Verify before flipping

With a pilot user who is in `app-restricted` only (or `sudo -l -U <user>`
plus probes):

```
sudo -l -U <pilot>                          # exactly the scoped grants, nothing else
sudo systemctl restart <svc>                # allowed
sudo systemctl restart <name>.timer         # allowed — timers grant the .timer spelling only
sudo systemctl restart <quadlet>.service    # allowed — quadlets grant the generated name
sudo systemctl enable <quadlet>.service     # DENIED — quadlet actions are lifecycle-only
sudo systemctl restart sshd                 # DENIED — foreign unit
sudo journalctl -u <svc>                    # granted spellings only; argument order matters
```

When the profile carries `local_groups`: a **fresh** ssh login's `id`
shows the service group; an existing session's does not (pam_group is
per-login). That check plus a write into the group-writable dir proves the
pam path.

## 6. The flip — order matters

1. **Refresh the baseline only after** the footprint and profile are
   committed (`--accept-all` erases the forensic diff):
   `sudo treadmark files update --accept-all --config /etc/treadmark/treadmark-footprint-linux.yaml`
2. **AD**: remove the user(s) from `<hostname>-app_full` and add them
   directly to `<hostname>-app_restricted`. Manual today — a wrapper
   playbook following playbook 1's `microsoft.ad.group` + Vault pattern
   (`members: add/remove`) is documented future work.
3. **Enforce on the host** — membership is cached and wheel was granted at
   login, so the flip is only real after:
   `sudo loginctl terminate-user <user>` (each affected user, or a reboot
   window), then `sudo sss_cache -E`.
4. **Prove it**: fresh login → `id` shows no wheel; `sudo dnf install zsh`
   (or `apt-get install`) denied; the scoped `systemctl` verbs still work.

Tell the customer their first command on next login: `sudo -l`.

## 7. Record

Archive in the ops record: `footprint-<app>.json`, the applied profile,
the entity (`<hostname>-app_restricted`), the server, and the date. Change
windows re-run this whole skill from step 1 (new capture after their new
work; the old baseline refresh in step 6 made that diff clean).

## Revocation / decommission

Same inputs, plus the two cleanup keys — `--tags cleanup` selects the
cleanup tasks, `-e declarative_access_force_cleanup=true` arms them (either
alone does nothing):

```
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @<app>-access.yml -e "group_name=<hostname>-app_restricted" \
  -l <host> --tags cleanup -e declarative_access_force_cleanup=true
```

Removes the sudoers file, `group.conf` mappings, lingering, and the ACLs
(including defaults). Ownership is never reverted — re-chown deliberately
if needed. `--skip-tags login` is only for simulated hosts without realmd;
real AD hosts drop `--skip-tags` but still need both cleanup keys. Finish
by removing the AD memberships (and the groups, at decommission).
